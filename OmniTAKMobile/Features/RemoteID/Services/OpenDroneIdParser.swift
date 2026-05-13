//
//  OpenDroneIdParser.swift
//  OmniTAKMobile
//
//  Decodes ASTM F3411-22a / OpenDroneID frames from raw Bluetooth
//  Remote ID service data. Pure functions — no CoreBluetooth deps,
//  fully testable in XCTest. Mirrors the Android `OpenDroneIdParser`
//  Kotlin object so both clients agree on the wire format.
//

import Foundation

enum OpenDroneIdParser {

    // MARK: - Public API

    /// Decode a single 25-byte ASTM message buffer.
    /// Returns nil when the buffer is the wrong length or
    /// unrecognisable; otherwise returns a typed
    /// `OpenDroneIdMessage` (which may be `.unknown` for
    /// not-yet-decoded message types).
    static func parseMessage(_ buf: [UInt8], offset: Int = 0) -> OpenDroneIdMessage? {
        guard offset >= 0,
              buf.count - offset >= OpenDroneIdMessage.messageTotalBytes else { return nil }

        let header = Int(buf[offset])
        let messageType = (header >> 4) & 0xF
        let protocolVersion = header & 0xF

        switch messageType {
        case OpenDroneIdMessage.MessageType.basicId.rawValue:
            return parseBasicId(buf, bodyOffset: offset + 1, protocolVersion: protocolVersion)
        case OpenDroneIdMessage.MessageType.location.rawValue:
            return parseLocation(buf, bodyOffset: offset + 1, protocolVersion: protocolVersion)
        default:
            return .unknown(messageType: messageType, protocolVersion: protocolVersion)
        }
    }

    /// Decode a Message Pack frame — the BT5 extended-advertising
    /// structure that bundles BasicID + Location + System + … into
    /// one broadcast. Pack header is 3 bytes (type+version, then
    /// single-message size, then count), followed by N × 25-byte
    /// messages.
    static func parseMessagePack(_ buf: [UInt8], offset: Int = 0) -> [OpenDroneIdMessage] {
        guard offset >= 0, buf.count - offset >= 3 else { return [] }

        let header = Int(buf[offset])
        let messageType = (header >> 4) & 0xF
        guard messageType == OpenDroneIdMessage.MessageType.messagePack.rawValue else { return [] }

        let singleMessageSize = Int(buf[offset + 1])
        let numMessages = Int(buf[offset + 2])
        guard singleMessageSize == OpenDroneIdMessage.messageTotalBytes,
              numMessages > 0,
              buf.count - offset >= 3 + numMessages * singleMessageSize else { return [] }

        var out: [OpenDroneIdMessage] = []
        out.reserveCapacity(numMessages)
        for i in 0..<numMessages {
            let msgOffset = offset + 3 + i * singleMessageSize
            if let parsed = parseMessage(buf, offset: msgOffset) {
                out.append(parsed)
            }
        }
        return out
    }

    /// Decode the BLE `service_data` payload as captured by
    /// `CBAdvertisementDataServiceDataKey` for CBUUID(0xFFFA). Data
    /// begins with a 1-byte application code (0x0D for OpenDroneID)
    /// + 1-byte counter, then the message body or message pack.
    static func parseServiceData(_ serviceData: [UInt8]) -> [OpenDroneIdMessage] {
        guard serviceData.count >= 3 else { return [] }
        let appCode = Int(serviceData[0])
        guard appCode == openDroneIdAppCode else { return [] }

        // Byte 1 is the per-message counter — useful for replay
        // detection, not needed to decode.
        let msgOffset = 2
        let header = Int(serviceData[msgOffset])
        let messageType = (header >> 4) & 0xF

        if messageType == OpenDroneIdMessage.MessageType.messagePack.rawValue {
            return parseMessagePack(serviceData, offset: msgOffset)
        } else if let single = parseMessage(serviceData, offset: msgOffset) {
            return [single]
        } else {
            return []
        }
    }

    /// Convenience: feed `Data` (e.g. directly from CoreBluetooth
    /// advertisement service-data dictionaries) without forcing
    /// callers to materialise a `[UInt8]`.
    static func parseServiceData(_ serviceData: Data) -> [OpenDroneIdMessage] {
        parseServiceData([UInt8](serviceData))
    }

    // MARK: - Private decoders

    private static func parseBasicId(
        _ buf: [UInt8],
        bodyOffset: Int,
        protocolVersion: Int
    ) -> OpenDroneIdMessage {
        let typeByte = Int(buf[bodyOffset])
        let idType = OpenDroneIdMessage.IdType.from(code: (typeByte >> 4) & 0xF)
        let uaType = OpenDroneIdMessage.UaType.from(code: typeByte & 0xF)

        // UAS ID — 20 ASCII bytes, null-padded. Strip trailing
        // zero bytes and whitespace.
        let idStart = bodyOffset + 1
        let idEnd = idStart + uasIdBytes
        var nullTerm = idEnd
        for i in idStart..<idEnd {
            if buf[i] == 0 {
                nullTerm = i
                break
            }
        }
        let idData = Data(buf[idStart..<nullTerm])
        let uasId = String(data: idData, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return .basicId(
            protocolVersion: protocolVersion,
            idType: idType,
            uaType: uaType,
            uasId: uasId
        )
    }

    private static func parseLocation(
        _ buf: [UInt8],
        bodyOffset: Int,
        protocolVersion: Int
    ) -> OpenDroneIdMessage {
        let statusByte = Int(buf[bodyOffset])
        let operationalStatus = OpenDroneIdMessage.OperationalStatus.from(code: (statusByte >> 4) & 0xF)
        let heightType = OpenDroneIdMessage.HeightType.from(code: (statusByte >> 2) & 0x1)
        let ewDirSegment = (statusByte >> 1) & 0x1
        let speedMult = statusByte & 0x1

        // Track direction: 0-179, with EW-segment bit indicating
        // the 180-359 half.
        let trackByte = Int(buf[bodyOffset + 1])
        let trackDirectionDeg = ewDirSegment == 1 ? trackByte + 180 : trackByte

        // Speed encoding (ASTM F3411 §5.4.4.4):
        //   SM=0 → 0.25 m/s per unit (0..63.75 m/s)
        //   SM=1 → 0.75 m/s per unit + 63.75 m/s offset
        let speedByte = Int(buf[bodyOffset + 2])
        let groundSpeedMs: Double = speedMult == 0
            ? Double(speedByte) * 0.25
            : Double(speedByte) * 0.75 + 255.0 * 0.25

        // Vertical speed: signed 8-bit, each unit = 0.5 m/s.
        let verticalSpeedMs = Double(Int8(bitPattern: buf[bodyOffset + 3])) * 0.5

        // Latitude / Longitude: signed little-endian int32, degrees × 1e7.
        let latRaw = readInt32LE(buf, offset: bodyOffset + 4)
        let lonRaw = readInt32LE(buf, offset: bodyOffset + 8)
        let latitude = Double(latRaw) / 1e7
        let longitude = Double(lonRaw) / 1e7

        // Altitudes: unsigned 16-bit, each unit = 0.5 m, offset = -1000 m.
        let pressureAlt = decodeAltitude(readUInt16LE(buf, offset: bodyOffset + 12))
        let geodeticAlt = decodeAltitude(readUInt16LE(buf, offset: bodyOffset + 14))
        let heightAboveTakeoff = decodeAltitude(readUInt16LE(buf, offset: bodyOffset + 16))

        let accByte = Int(buf[bodyOffset + 18])
        let horizontalAccuracyM = horizontalAccuracyTable[(accByte >> 4) & 0xF]
        let verticalAccuracyM = verticalAccuracyTable[accByte & 0xF]

        let timestampRaw = readUInt16LE(buf, offset: bodyOffset + 21)
        let timestampSec: Int? = timestampRaw == 0xFFFF ? nil : timestampRaw / 10

        return .location(.init(
            protocolVersion: protocolVersion,
            operationalStatus: operationalStatus,
            heightType: heightType,
            trackDirectionDeg: trackDirectionDeg,
            groundSpeedMs: groundSpeedMs,
            verticalSpeedMs: verticalSpeedMs,
            latitude: latitude,
            longitude: longitude,
            pressureAltitudeM: pressureAlt,
            geodeticAltitudeM: geodeticAlt,
            heightAboveTakeoffM: heightAboveTakeoff,
            horizontalAccuracyM: horizontalAccuracyM,
            verticalAccuracyM: verticalAccuracyM,
            timestampSec: timestampSec
        ))
    }

    // MARK: - Helpers

    private static func readInt32LE(_ buf: [UInt8], offset: Int) -> Int32 {
        let u =
            UInt32(buf[offset]) |
            (UInt32(buf[offset + 1]) << 8) |
            (UInt32(buf[offset + 2]) << 16) |
            (UInt32(buf[offset + 3]) << 24)
        return Int32(bitPattern: u)
    }

    private static func readUInt16LE(_ buf: [UInt8], offset: Int) -> Int {
        Int(buf[offset]) | (Int(buf[offset + 1]) << 8)
    }

    private static func decodeAltitude(_ raw: Int) -> Double? {
        raw == 0 ? nil : Double(raw) * 0.5 - 1000.0
    }

    private static let openDroneIdAppCode = 0x0D
    private static let uasIdBytes = 20

    /// ASTM F3411 §5.4.4.10 — Horizontal Accuracy in metres.
    private static let horizontalAccuracyTable: [Double?] = [
        nil,                 // 0 = unknown
        18520.0, 7408.0, 3704.0, 1852.0, 926.0, 555.6, 185.2, 92.6, 30.0, 10.0, 3.0, 1.0,
        nil, nil, nil,       // 13-15 reserved
    ]

    /// ASTM F3411 §5.4.4.11 — Vertical Accuracy in metres.
    private static let verticalAccuracyTable: [Double?] = [
        nil, 150.0, 45.0, 25.0, 10.0, 3.0, 1.0,
        nil, nil, nil, nil, nil, nil, nil, nil, nil,
    ]
}
