//
//  GybManager.swift
//  OmniTAKMobile
//
//  Lifecycle + glue for the gyb_detect external drone detector. Owns the BLE
//  client, parses its JSON stream, and funnels drone detections through the
//  SHARED `RemoteIdTrackStore` so gyb (WiFi) sightings merge with the phone's
//  on-device (BLE) sightings into one `RID-{uasId}` marker.
//
//  On/off is driven by @AppStorage("gybDetectorEnabled") from Settings, the
//  same pattern as RemoteIdAppBridge. Mirrors the Android GybManager wiring
//  in OmniTAKApp so both platforms behave identically.
//

import Foundation
import Combine
import os

@MainActor
final class GybManager: ObservableObject {

    static let shared = GybManager()

    let client = GybBLEClient()

    /// Status surfaced in the connection UI (mirrors the omni-COT dashboard).
    @Published private(set) var batteryLevel: Double?     // 0…1
    @Published private(set) var droneCount: Int = 0
    @Published private(set) var deviceModel: String?
    @Published private(set) var deviceSerial: String?

    private var enabled = false
    /// Its own track store, but it pushes into the shared marker pipeline via
    /// RemoteIdAppBridge so dedup with on-device BLE happens at the UID level.
    private let trackStore = RemoteIdTrackStore()
    private var lastRecvMethod: [String: Int] = [:]
    private var purgeTimer: Timer?

    private let log = Logger(subsystem: "com.omnitak.mobile", category: "gyb")

    private init() {
        client.onLine = { [weak self] line in
            self?.handleLine(line)
        }
    }

    /// Mirror the @AppStorage value. Idempotent.
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value {
            client.reconnectLast()
            startPurgeTimer()
        } else {
            client.disconnect()
            purgeTimer?.invalidate()
            purgeTimer = nil
            clearAll()
        }
    }

    // MARK: - Stream handling

    private func handleLine(_ line: String) {
        // Defensive enabled-gate: detections must never flow into the
        // marker pipeline while the Settings toggle is OFF (the purge
        // timer doesn't run in that state, so markers would never go
        // stale). The BLE client also refuses to (re)connect when
        // disabled, so this is belt-and-braces.
        guard enabled else { return }
        guard let msg = GybDetectionParser.parse(line) else { return }
        switch msg {
        case let .deviceInfo(model, serial, _):
            deviceModel = model
            deviceSerial = serial
        case let .battery(level):
            batteryLevel = level
        case let .drone(uasId, messages, recvMethod):
            lastRecvMethod[uasId] = recvMethod
            let changed = trackStore.ingest(messages, fallbackId: uasId)
            for id in changed {
                if let track = trackStore.get(id) {
                    let note = " / via gyb (\(GybDetectionParser.recvMethodLabel(recvMethod)))"
                    RemoteIdAppBridge.shared.ingestExternalTrack(track, sourceNote: note)
                }
            }
            droneCount = trackStore.snapshot().count
        }
    }

    // MARK: - Stale purge

    private func startPurgeTimer() {
        purgeTimer?.invalidate()
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.purge() }
        }
    }

    private func purge() {
        let removed = trackStore.purgeStale()
        for id in removed {
            RemoteIdAppBridge.shared.removeExternalTrack(uasId: id)
            lastRecvMethod.removeValue(forKey: id)
        }
        droneCount = trackStore.snapshot().count
    }

    private func clearAll() {
        let ids = trackStore.snapshot().map { $0.uasId }
        trackStore.clear()
        for id in ids { RemoteIdAppBridge.shared.removeExternalTrack(uasId: id) }
        droneCount = 0
        batteryLevel = nil
        deviceModel = nil
        deviceSerial = nil
    }
}
