//
//  UASManager.swift
//  OmniTAKMobile
//
//  ObservableObject that owns the live MAVLink link to one vehicle
//  and publishes a DroneState the SwiftUI layer can bind to. Mirrors
//  the role of the Android sibling `UASManager.kt`.
//
//  All mutations to @Published state are hopped to the main actor so
//  SwiftUI never observes a torn read — the MAVLinkConnection delivers
//  messages on its own background queue.
//

import Combine
import Foundation
import Network

@MainActor
final class UASManager: ObservableObject {
    static let shared = UASManager()

    @Published private(set) var state = DroneState()
    @Published private(set) var connecting = false
    @Published private(set) var lastError: String? = nil

    /// Operator's chosen camera source. Wired to the UAS Video PIP.
    /// Survives the lifetime of the manager; resets on app launch
    /// (no DataStore equivalent yet — follow-up).
    @Published var videoSource: VideoSource = .none

    /// Operator callsign that this app advertises in CoT events for
    /// the drone. Defaults to a stable per-platform string.
    @Published var droneCallsign: String = "OmniTAK-UAS"

    /// Operator's chosen geofence radius (metres). 0 = disabled.
    @Published var geofenceMeters: Int = 500

    private let mavlink = MAVLinkConnection()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        mavlink.onMessage = { [weak self] msg in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.ingest(msg)
            }
        }
        mavlink.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(state)
            }
        }
    }

    // MARK: - Connection lifecycle

    func connect(host: String, port: Int, callsign: String) {
        droneCallsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        connecting = true
        state = DroneState() // reset between sessions
        mavlink.connect(host: host, port: port)
    }

    func disconnect() {
        mavlink.disconnect()
        connecting = false
        state = DroneState()
    }

    // MARK: - Commands

    /// Send arm / disarm. Vehicle must be on a holdable mode for
    /// arming to succeed; we don't enforce that here — the autopilot
    /// is authoritative.
    func arm(_ arm: Bool) {
        mavlink.sendCommandLong(
            targetSystem: UInt8(max(1, state.systemId)),
            targetComponent: UInt8(state.componentId),
            command: 400, // MAV_CMD_COMPONENT_ARM_DISARM
            params: [arm ? 1 : 0, 0, 0, 0, 0, 0, 0]
        )
    }

    /// Take off to relative altitude in metres (AGL above launch).
    func takeoff(toMetersAgl meters: Double) {
        mavlink.sendCommandLong(
            targetSystem: UInt8(max(1, state.systemId)),
            targetComponent: UInt8(state.componentId),
            command: 22, // MAV_CMD_NAV_TAKEOFF
            params: [0, 0, 0, 0, 0, 0, Float(meters)]
        )
    }

    /// Return-to-launch.
    func returnToLaunch() {
        mavlink.sendCommandLong(
            targetSystem: UInt8(max(1, state.systemId)),
            targetComponent: UInt8(state.componentId),
            command: 20, // MAV_CMD_NAV_RETURN_TO_LAUNCH
            params: Array(repeating: 0, count: 7)
        )
    }

    // MARK: - Telemetry ingestion

    private func ingest(_ msg: ParsedMessage) {
        switch msg {
        case .heartbeat(let hb):
            state.lastHeartbeatMs = Int64(Date().timeIntervalSince1970 * 1000)
            state.autopilot = MAVAutopilot(raw: hb.autopilot)
            state.vehicleType = MAVType(raw: hb.type)
            let wasArmed = state.armed
            state.armed = hb.armed
            if hb.armed && !wasArmed {
                state.armedAtMs = state.lastHeartbeatMs
            } else if !hb.armed {
                state.armedAtMs = nil
            }
        case .globalPositionInt(let gpi):
            state.latDeg = Double(gpi.latDegE7) / 1e7
            state.lonDeg = Double(gpi.lonDegE7) / 1e7
            state.altMsl = Double(gpi.altMslMm) / 1000.0
            state.altAgl = Double(gpi.altAglMm) / 1000.0
            if gpi.hdgCdeg != UInt16.max {
                state.headingDeg = Double(gpi.hdgCdeg) / 100.0
            }
            // Ground speed from horizontal velocity components.
            let vx: Double = Double(gpi.vxCmS) / 100.0
            let vy: Double = Double(gpi.vyCmS) / 100.0
            let speedSq: Double = vx * vx + vy * vy
            state.groundSpeedMps = speedSq.squareRoot()
        case .gpsRawInt(let gps):
            state.gpsFixType = Int(gps.fixType)
            state.satellitesVisible = Int(gps.satellitesVisible)
        case .sysStatus(let s):
            state.batteryVoltage = s.voltageBatteryMv == UInt16.max
                ? nil : Double(s.voltageBatteryMv) / 1000.0
            state.batteryRemaining = s.batteryRemainingPct < 0 ? nil : Int(s.batteryRemainingPct)
        case .batteryStatus(let b):
            state.batteryRemaining = b.batteryRemainingPct < 0 ? nil : Int(b.batteryRemainingPct)
        case .attitude, .commandAck, .unknown:
            break
        }
    }

    private func handleConnectionState(_ s: Network.NWConnection.State) {
        switch s {
        case .ready:
            connecting = false
        case .failed(let err):
            connecting = false
            lastError = err.localizedDescription
        case .cancelled:
            connecting = false
        default:
            break
        }
    }
}

