//
//  OpenDroneIdMessage.swift
//  OmniTAKMobile
//
//  ASTM F3411-22a / OpenDroneID parsed message types — the Swift
//  mirror of the Android `OpenDroneIdMessage` sealed class. Both
//  platforms decode the same wire format and emit the same shape
//  so the Remote ID pipeline behaves identically across clients.
//
//  Phase 2 scope: BasicID + Location only. Other ASTM types return
//  `unknown` for now — they carry useful metadata (operator location,
//  description string, signatures) but aren't required to plot a
//  track on the map.
//

import Foundation

/// Parsed OpenDroneID / ASTM F3411-22a messages.
enum OpenDroneIdMessage: Equatable {
    /// Basic ID — carries the UAS identifier used to dedupe frames
    /// into a single track.
    case basicId(
        protocolVersion: Int,
        idType: IdType,
        uaType: UaType,
        uasId: String
    )

    /// Location/Vector — lat/lon and the rest of the fields needed
    /// to plot the track. Lat/lon are decoded from signed 32-bit
    /// little-endian integers, degrees × 1e7.
    case location(Location)

    /// Unparsed / unknown message type. Kept so the scanner can
    /// count non-fatal frames it skipped, useful for diagnostics.
    case unknown(messageType: Int, protocolVersion: Int)

    /// ASTM message type code (4 bits, 0x0–0xF).
    var messageType: Int {
        switch self {
        case .basicId: return MessageType.basicId.rawValue
        case .location: return MessageType.location.rawValue
        case let .unknown(messageType, _): return messageType
        }
    }

    enum MessageType: Int {
        case basicId = 0x0
        case location = 0x1
        case authentication = 0x2
        case selfId = 0x3
        case system = 0x4
        case operatorId = 0x5
        case messagePack = 0xF
    }

    enum IdType: Int, Equatable {
        case none = 0
        /// Manufacturer-assigned serial.
        case serialNumber = 1
        /// FAA-issued operator registration.
        case registration = 2
        /// UTM-assigned UUID (newer FAA Remote ID path).
        case utmAssignedUUID = 3
        /// Per-flight session ID.
        case sessionId = 4
        case reserved = 5

        static func from(code: Int) -> IdType {
            IdType(rawValue: code) ?? .reserved
        }
    }

    enum UaType: Int, Equatable {
        case undeclared = 0
        case aeroplane = 1
        /// Multirotor — the DJI Mavic / consumer drone class.
        case helicopterOrMultirotor = 2
        case gyroplane = 3
        case hybridLift = 4
        case ornithopter = 5
        case glider = 6
        case kite = 7
        case freeBalloon = 8
        case captiveBalloon = 9
        case airship = 10
        case freeFall = 11
        case rocket = 12
        case tetheredPoweredAircraft = 13
        case groundObstacle = 14
        case other = 15

        static func from(code: Int) -> UaType {
            UaType(rawValue: code) ?? .other
        }
    }

    enum OperationalStatus: Int, Equatable {
        case undeclared = 0
        case ground = 1
        case airborne = 2
        case emergency = 3
        case remoteIdSystemFailure = 4

        static func from(code: Int) -> OperationalStatus {
            OperationalStatus(rawValue: code) ?? .undeclared
        }
    }

    enum HeightType: Int, Equatable {
        case aboveTakeoff = 0
        case aboveGroundLevel = 1

        static func from(code: Int) -> HeightType {
            code == 1 ? .aboveGroundLevel : .aboveTakeoff
        }
    }

    /// Decoded Location/Vector payload.
    struct Location: Equatable {
        let protocolVersion: Int
        let operationalStatus: OperationalStatus
        let heightType: HeightType
        let trackDirectionDeg: Int
        let groundSpeedMs: Double
        let verticalSpeedMs: Double
        let latitude: Double
        let longitude: Double
        let pressureAltitudeM: Double?
        let geodeticAltitudeM: Double?
        let heightAboveTakeoffM: Double?
        let horizontalAccuracyM: Double?
        let verticalAccuracyM: Double?
        let timestampSec: Int?

        /// True when both lat and lon decoded to non-zero,
        /// non-NaN values.
        var hasValidPosition: Bool {
            !latitude.isNaN && !longitude.isNaN &&
                !(latitude == 0 && longitude == 0)
        }
    }

    /// Each individual ASTM message is exactly 25 bytes after the
    /// 1-byte header.
    static let messageBodyBytes = 24
    static let messageTotalBytes = 25

    /// Service UUID (BT-SIG short form) for FAA Remote ID.
    static let serviceUuid16: UInt16 = 0xFFFA
}
