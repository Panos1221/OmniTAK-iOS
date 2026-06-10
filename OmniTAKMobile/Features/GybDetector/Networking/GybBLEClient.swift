//
//  GybBLEClient.swift
//  OmniTAKMobile
//
//  CoreBluetooth central for the gyb_detect drone detector. Mirrors the
//  MeshtasticBLEClient pattern (scan by service UUID → connect → discover →
//  subscribe to a notify characteristic) but the gyb stream is plain
//  newline-delimited JSON, not protobuf.
//
//  The firmware (ghostnet-fw/src/gatt_link.cpp) chunks each JSON object into
//  20-byte notifications and terminates it with '\n'. We buffer inbound bytes
//  and emit one `onLine` callback per complete object. iOS cannot use the
//  legacy Bluetooth Classic SPP link the ATAK plugin used, so BLE GATT is the
//  only viable transport here — and it pairs in-app with no Settings detour.
//

import Foundation
import CoreBluetooth
import os

enum GybBLEUUID {
    static let service = CBUUID(string: "e3f1b8a0-9c1d-4a2e-9b00-67796236d701")
    static let detection = CBUUID(string: "e3f1b8a0-9c1d-4a2e-9b00-67796236d702")
}

@MainActor
final class GybBLEClient: NSObject, ObservableObject {

    // Reuses the Meshtastic-defined DiscoveredBLEDevice value type.
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published private(set) var connectedDeviceName: String?

    /// One callback per reassembled JSON line off the GATT stream.
    var onLine: ((String) -> Void)?

    private let log = Logger(subsystem: "com.omnitak.mobile", category: "gyb")
    private let deviceNamePrefix = "gyb_detect"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxBuffer = Data()

    /// Last connected peripheral UUID for auto-reconnect.
    private static let lastDeviceKey = "gyb_last_device_uuid"
    /// Settings toggle key (@AppStorage in SettingsView / OmniTAKMobileApp).
    /// The client consults it directly so a poweredOn callback at app
    /// launch can't reconnect-and-plot while the feature is OFF.
    private static let enabledKey = "gybDetectorEnabled"

    /// Pending delayed reconnect attempt after an unexpected link drop.
    /// Cancelled by an intentional disconnect (toggle off / user) or a
    /// successful connect.
    private var reconnectWork: DispatchWorkItem?
    /// Consecutive failed-reconnect counter driving the backoff delay.
    private var reconnectAttempts = 0
    /// True while the last disconnect was deliberate, so the
    /// didDisconnectPeripheral callback doesn't fight it with a retry.
    private var userInitiatedDisconnect = false

    private var featureEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Scan

    func startScanning() {
        guard central.state == .poweredOn else {
            log.info("startScanning deferred — central not powered on")
            return
        }
        discoveredDevices.removeAll()
        isScanning = true
        // Filter by the gyb service UUID — the firmware advertises it.
        central.scanForPeripherals(
            withServices: [GybBLEUUID.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        log.info("scanning for gyb detectors")
    }

    func stopScanning() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    // MARK: - Connect

    func connect(to device: DiscoveredBLEDevice) {
        stopScanning()
        userInitiatedDisconnect = false
        cancelPendingReconnect()
        peripheral = device.peripheral
        peripheral?.delegate = self
        central.connect(device.peripheral, options: nil)
        log.info("connecting to \(device.name, privacy: .public)")
    }

    func disconnect() {
        // Deliberate teardown (Settings toggle off / user action) — make
        // sure no queued auto-reconnect resurrects the link.
        userInitiatedDisconnect = true
        cancelPendingReconnect()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        rxBuffer.removeAll()
        isConnected = false
        connectedDeviceName = nil
    }

    /// Try to silently reconnect to the last paired detector. No-op while
    /// the Settings toggle is OFF — GybManager.shared exists from app
    /// launch, and the unconditional poweredOn reconnect used to re-link
    /// the detector (and plot markers with no purge timer running) with
    /// the feature disabled.
    func reconnectLast() {
        guard featureEnabled else { return }
        guard central.state == .poweredOn,
              let uuidStr = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let uuid = UUID(uuidString: uuidStr) else { return }
        userInitiatedDisconnect = false
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = known.first {
            peripheral = p
            p.delegate = self
            central.connect(p, options: nil)
            log.info("auto-reconnecting to last gyb detector")
        }
    }

    // MARK: - Auto-reconnect (unexpected drops)

    private func cancelPendingReconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectAttempts = 0
    }

    /// Schedule a delayed reconnect after an unexpected link drop (range,
    /// detector reboot). The firmware restarts advertising on disconnect,
    /// so the phone just has to try again — previously the stream silently
    /// died until an app relaunch or toggle cycle. Backoff: 1s, 2s, 4s …
    /// capped at 30s; cancelled by user disconnect, toggle off, or a
    /// successful connect.
    private func scheduleReconnectIfNeeded() {
        guard !userInitiatedDisconnect,
              featureEnabled,
              UserDefaults.standard.string(forKey: Self.lastDeviceKey) != nil else { return }
        reconnectWork?.cancel()
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 30.0)
        log.info("gyb link dropped — reconnect attempt \(self.reconnectAttempts) in \(delay, privacy: .public)s")
        let work = DispatchWorkItem {
            Task { @MainActor [weak self] in
                guard let self, !self.isConnected else { return }
                self.reconnectLast()
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - RX reassembly

    private func ingest(_ data: Data) {
        rxBuffer.append(data)
        // Split on newline; emit each complete line, keep the remainder.
        while let nl = rxBuffer.firstIndex(of: 0x0A) {
            let lineData = rxBuffer.subdata(in: rxBuffer.startIndex..<nl)
            rxBuffer.removeSubrange(rxBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onLine?(trimmed) }
        }
        // Guard against a runaway buffer if a '\n' never arrives.
        if rxBuffer.count > 8192 { rxBuffer.removeAll() }
    }
}

// MARK: - CBCentralManagerDelegate

extension GybBLEClient: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.reconnectLast()
            case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
                self.isConnected = false
                self.isScanning = false
            @unknown default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "gyb detector"
        // Defensive: only surface gyb-named devices even though we filter by
        // service UUID (some adverts omit the name in the primary packet).
        let name = advName
        Task { @MainActor in
            guard name.lowercased().hasPrefix(self.deviceNamePrefix) || peripheral.name == nil
                    || (peripheral.name?.lowercased().hasPrefix(self.deviceNamePrefix) ?? false) else {
                // Still allow service-matched devices through even if unnamed.
                return
            }
            let device = DiscoveredBLEDevice(id: peripheral.identifier, name: name,
                                             rssi: RSSI.intValue, peripheral: peripheral)
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[idx] = device
            } else {
                self.discoveredDevices.append(device)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.isConnected = true
            self.connectedDeviceName = peripheral.name
            self.rxBuffer.removeAll()
            self.cancelPendingReconnect()
            self.userInitiatedDisconnect = false
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
            peripheral.discoverServices([GybBLEUUID.service])
            self.log.info("connected; discovering gyb service")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            self.connectedDeviceName = nil
            self.scheduleReconnectIfNeeded()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            self.connectedDeviceName = nil
            self.rxBuffer.removeAll()
            // Unexpected drop (range / detector reboot) → retry with
            // backoff while the feature is enabled. Intentional
            // disconnects set userInitiatedDisconnect and skip this.
            self.scheduleReconnectIfNeeded()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension GybBLEClient: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == GybBLEUUID.service {
            peripheral.discoverCharacteristics([GybBLEUUID.detection], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        for ch in chars where ch.uuid == GybBLEUUID.detection {
            peripheral.setNotifyValue(true, for: ch)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == GybBLEUUID.detection,
              let value = characteristic.value else { return }
        Task { @MainActor in
            self.ingest(value)
        }
    }
}
