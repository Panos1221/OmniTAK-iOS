//
//  DroneState.swift
//  OmniTAKMobile
//
//  Drone state snapshot derived from MAVLink telemetry. Mirrors the
//  Android sibling (OmniTAK-Android/.../data/uas/DroneState.kt).
//
//  This is a value type — UASManager publishes snapshots rather than
//  mutating a shared object so SwiftUI views never see torn reads.
//

import Foundation

struct DroneState: Equatable {
    /// Wall-clock ms (monotonic since UNIX epoch) of the last received
    /// HEARTBEAT. `nil` = never connected.
    var lastHeartbeatMs: Int64? = nil

    var systemId: Int = 0
    var componentId: Int = 0
    var autopilot: MAVAutopilot = .invalid
    var vehicleType: MAVType = .generic
    var armed: Bool = false

    /// Wall-clock ms when [armed] first flipped true. Used by the HUD
    /// elapsed-flight timer.
    var armedAtMs: Int64? = nil

    // -------- Position (GLOBAL_POSITION_INT) --------
    /// Decimal degrees. `nil` until the first position fix.
    var latDeg: Double? = nil
    var lonDeg: Double? = nil
    /// Meters MSL.
    var altMsl: Double? = nil
    /// Meters AGL (autopilot's terrain-referenced altitude).
    var altAgl: Double? = nil
    /// Heading in degrees (0-360). `nil` if heading is unknown.
    var headingDeg: Double? = nil
    /// Ground speed m/s.
    var groundSpeedMps: Double? = nil

    // -------- GPS quality (GPS_RAW_INT) --------
    var gpsFixType: Int = 0
    var satellitesVisible: Int = 0

    // -------- Battery (SYS_STATUS / BATTERY_STATUS) --------
    var batteryVoltage: Double? = nil
    var batteryRemaining: Int? = nil

    // -------- Home position (set at first ARMED) --------
    var homeLatDeg: Double? = nil
    var homeLonDeg: Double? = nil

    /// True if we've had a HEARTBEAT in the last 5 s — matches the
    /// Android RAS-A IOP §HEARTBEAT timeout.
    func isConnected(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard let last = lastHeartbeatMs else { return false }
        return (nowMs - last) < 5_000
    }

    var hasFix: Bool { latDeg != nil && lonDeg != nil }
}

/// MAVLink MAV_AUTOPILOT enum (subset used by the HUD).
enum MAVAutopilot: UInt8, Equatable {
    case generic = 0
    case ardupilot = 3
    case px4 = 12
    case invalid = 8

    init(raw: UInt8) {
        self = MAVAutopilot(rawValue: raw) ?? .invalid
    }

    var displayName: String {
        switch self {
        case .ardupilot: return "ArduPilot"
        case .px4: return "PX4"
        case .generic: return "Generic"
        case .invalid: return "Unknown"
        }
    }
}

/// MAVLink MAV_TYPE enum (subset — air/ground/surface bucketing).
enum MAVType: UInt8, Equatable {
    case generic = 0
    case fixedWing = 1
    case quadrotor = 2
    case coaxial = 3
    case helicopter = 4
    case groundRover = 10
    case surfaceBoat = 11
    case submarine = 12
    case hexarotor = 13
    case octorotor = 14
    case tricopter = 15
    case vtol = 19

    init(raw: UInt8) {
        self = MAVType(rawValue: raw) ?? .generic
    }

    /// Operator-facing platform label. The Android sibling derives map
    /// behaviour (Fly Here vs Drive Here) from this.
    var platformLabel: String {
        switch self {
        case .quadrotor, .hexarotor, .octorotor, .tricopter, .coaxial,
             .helicopter, .vtol, .fixedWing:
            return "UAS"
        case .groundRover:
            return "UGV"
        case .surfaceBoat, .submarine:
            return "USV"
        default:
            return "UAS"
        }
    }
}
