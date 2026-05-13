//
//  RemoteIdScanner.swift
//  OmniTAKMobile
//
//  CoreBluetooth scanner for FAA Remote ID broadcasts. Listens for
//  advertisements carrying the 16-bit service UUID 0xFFFA
//  (OpenDroneID), pulls the service-data field out of each scan
//  record, parses it via `OpenDroneIdParser`, aggregates into
//  `RemoteIdTrack`s, and exposes change emissions to the rest of
//  the app.
//
//  ## What this catches
//  - BT4 Legacy advertising — older DJI fleet.
//  - BT5 Extended advertising — Mavic 3 / Air 3 / Mini 4 / Skydio 2+.
//    Whole Message Pack (Basic ID + Location + System) lands in one
//    broadcast on iPhone 11 and newer (CoreBluetooth supports
//    extended-adv reception on those models).
//
//  ## What this does NOT catch
//  - WiFi-Beacon Remote ID — Apple blocks WiFi monitor mode
//    entirely. That's where the gy6 hardware path (Phase 3) earns
//    its keep.
//  - Drones with Remote ID disabled or non-compliant builds.
//
//  ## Foreground vs background
//  - Foreground scanning with a service-UUID filter works without
//    special entitlements.
//  - Background scanning requires the `bluetooth-central`
//    UIBackgroundMode and *only* delivers advertisements when the
//    service UUID is explicitly listed in
//    `UIBackgroundModes` → `bluetooth-central`. Not enabled in
//    this initial version — drone detection is a foreground
//    feature for now.
//

import Foundation
import CoreBluetooth

/// Track-update emission published whenever one or more tracks
/// changed in a way the map should re-render (new sighting,
/// position move, or stale removal).
struct RemoteIdTrackUpdate {
    let changedUasIds: Set<String>
}

final class RemoteIdScanner: NSObject {

    /// FAA Remote ID service UUID (BT-SIG short form 0xFFFA).
    static let serviceUuid: CBUUID = CBUUID(string: "FFFA")

    private let trackStore: RemoteIdTrackStore
    private let stalePurgeInterval: TimeInterval

    private var centralManager: CBCentralManager?
    private var purgeTimer: Timer?
    private var running: Bool = false
    private var pendingStartAfterPoweredOn: Bool = false

    /// Callback fired on every track update. Set by the owner
    /// (typically the app delegate) to forward into the marker
    /// pipeline. Always invoked on the main thread so callers can
    /// touch UIKit/MapKit directly.
    var onTrackUpdate: ((RemoteIdTrackUpdate) -> Void)?

    /// Read-only snapshot of the current roster — handy on rebind.
    var tracks: [RemoteIdTrack] { trackStore.snapshot() }

    init(
        trackStore: RemoteIdTrackStore = RemoteIdTrackStore(),
        stalePurgeInterval: TimeInterval = 5.0
    ) {
        self.trackStore = trackStore
        self.stalePurgeInterval = stalePurgeInterval
        super.init()
    }

    /// Start scanning. Returns immediately; the actual scan kicks
    /// off once the central manager reaches `.poweredOn` state.
    /// Calling twice is a no-op.
    func start() {
        guard !running else { return }
        running = true
        pendingStartAfterPoweredOn = true

        if centralManager == nil {
            // Setting `restoreIdentifier` later would enable state
            // preservation, but we deliberately don't here — drone
            // detection is a foreground feature for now and the
            // simpler init avoids the system restoring scans across
            // process death.
            centralManager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        } else {
            beginScanIfPossible()
        }

        startStalePurgeTimer()
    }

    /// Stop scanning. Safe to call when not running.
    func stop() {
        guard running else { return }
        running = false
        pendingStartAfterPoweredOn = false
        purgeTimer?.invalidate()
        purgeTimer = nil

        centralManager?.stopScan()

        let drained = Set(trackStore.snapshot().map { $0.uasId })
        trackStore.clear()
        if !drained.isEmpty {
            onTrackUpdate?(.init(changedUasIds: drained))
        }
    }

    // MARK: - Private

    private func beginScanIfPossible() {
        guard running, let cm = centralManager, cm.state == .poweredOn else { return }
        // `allowDuplicates` is required so we keep getting
        // advertisement callbacks at the broadcast rate (~1 Hz)
        // instead of just the first sighting per peripheral.
        //
        // `withServices: nil` is deliberate — passing
        // `[Self.serviceUuid]` filters on the advertised service
        // class UUID list (AD types 0x02/0x03), but ASTM F3411
        // broadcasts 0xFFFA only in service data (AD type 0x16).
        // CoreBluetooth's filter never matches service-data UUIDs,
        // so a filtered scan silently sees nothing. Android hit the
        // same bug — see OmniTAK-Android 0.7.1 (fix 1/4). We instead
        // accept all advertisements and check the service-data
        // dictionary in `didDiscover`.
        cm.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func startStalePurgeTimer() {
        purgeTimer?.invalidate()
        purgeTimer = Timer.scheduledTimer(
            withTimeInterval: stalePurgeInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self = self else { return }
            let purged = self.trackStore.purgeStale()
            if !purged.isEmpty {
                self.onTrackUpdate?(.init(changedUasIds: purged))
            }
        }
    }
}

extension RemoteIdScanner: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if pendingStartAfterPoweredOn { beginScanIfPossible() }
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            // Bluetooth went away — flush in-flight tracks so the
            // map doesn't show stale ghosts.
            let drained = Set(trackStore.snapshot().map { $0.uasId })
            trackStore.clear()
            if !drained.isEmpty {
                onTrackUpdate?(.init(changedUasIds: drained))
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let serviceData = advertisementData[CBAdvertisementDataServiceDataKey]
            as? [CBUUID: Data] else { return }
        guard let raw = serviceData[Self.serviceUuid] else { return }

        let messages = OpenDroneIdParser.parseServiceData(raw)
        guard !messages.isEmpty else { return }

        let fallback = "PERIPHERAL-\(peripheral.identifier.uuidString)"
        let changed = trackStore.ingest(messages, fallbackId: fallback)
        if !changed.isEmpty {
            onTrackUpdate?(.init(changedUasIds: changed))
        }
    }
}
