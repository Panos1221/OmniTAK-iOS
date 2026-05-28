//
//  MAVLinkCodec.swift
//  OmniTAKMobile
//
//  Hand-rolled MAVLink 2 codec — just the subset we need for UAS
//  Quick Connect + drone telemetry. There is no actively-maintained
//  Swift MAVLink SPM package as of 2026-05, and the MAVSDK-Swift
//  gRPC wrapper is heavy. We only need ~8 message types, ~550 lines.
//
//  Frame format (MAVLink 2):
//
//      0xFD | LEN | INCOMPAT_FLAGS | COMPAT_FLAGS | SEQ |
//      SYS_ID | COMP_ID | MSG_ID[3] | PAYLOAD[LEN] | CRC[2] |
//      SIGNATURE[13]?
//
//  CRC algorithm: CRC-16/MCRF4XX ("X.25"), initial 0xFFFF, computed
//  over LEN..PAYLOAD plus the per-message CRC_EXTRA byte (a hash of
//  the message definition that catches sender/receiver dialect
//  mismatch). Per-message CRC_EXTRA values are taken from pymavlink's
//  common.xml generator output.
//
//  We use the standard "common" dialect. Signing is not supported —
//  any signed frame is dropped (we never set the signing flag when
//  sending, so SITL / PX4 / ArduPilot in default config talk to us
//  unsigned).
//

import Foundation

// MARK: - Message IDs (common dialect subset)

enum MAVMsg: UInt32 {
    case heartbeat = 0
    case sysStatus = 1
    case gpsRawInt = 24
    case attitude = 30
    case globalPositionInt = 33
    case commandLong = 76
    case commandAck = 77
    case batteryStatus = 147

    /// CRC_EXTRA byte for this message ID. Generated from common.xml
    /// by the pymavlink generator; hand-vended here for the subset we
    /// parse. If a dialect ever rev's these, frames will fail CRC and
    /// drop silently — exactly the behavior we want.
    var crcExtra: UInt8 {
        switch self {
        case .heartbeat: return 50
        case .sysStatus: return 124
        case .gpsRawInt: return 24
        case .attitude: return 39
        case .globalPositionInt: return 104
        case .commandLong: return 152
        case .commandAck: return 143
        case .batteryStatus: return 154
        }
    }

    /// Wire length of the message before MAVLink 2 trailing-zero
    /// truncation. Receivers must zero-pad truncated payloads back to
    /// this length before parsing.
    var wireLength: Int {
        switch self {
        case .heartbeat: return 9
        case .sysStatus: return 31
        case .gpsRawInt: return 30
        case .attitude: return 28
        case .globalPositionInt: return 28
        case .commandLong: return 33
        case .commandAck: return 10
        case .batteryStatus: return 54
        }
    }
}

// MARK: - Parsed messages

struct MAVMessages {
    struct Heartbeat {
        let customMode: UInt32
        let type: UInt8
        let autopilot: UInt8
        let baseMode: UInt8
        let systemStatus: UInt8
        let mavlinkVersion: UInt8
        var armed: Bool { (baseMode & 0x80) != 0 }   // MAV_MODE_FLAG_SAFETY_ARMED
    }

    struct GlobalPositionInt {
        let timeBootMs: UInt32
        let latDegE7: Int32
        let lonDegE7: Int32
        let altMslMm: Int32
        let altAglMm: Int32
        let vxCmS: Int16
        let vyCmS: Int16
        let vzCmS: Int16
        let hdgCdeg: UInt16   // 0..36000, UINT16_MAX (65535) = unknown
    }

    struct Attitude {
        let timeBootMs: UInt32
        let roll: Float
        let pitch: Float
        let yaw: Float
        let rollSpeed: Float
        let pitchSpeed: Float
        let yawSpeed: Float
    }

    struct GpsRawInt {
        let timeUsec: UInt64
        let latDegE7: Int32
        let lonDegE7: Int32
        let altMslMm: Int32
        let eph: UInt16
        let epv: UInt16
        let velCmS: UInt16
        let cogCdeg: UInt16
        let fixType: UInt8
        let satellitesVisible: UInt8
    }

    struct SysStatus {
        let sensorsPresent: UInt32
        let sensorsEnabled: UInt32
        let sensorsHealth: UInt32
        let load: UInt16
        let voltageBatteryMv: UInt16
        let currentBatteryCa: Int16
        let dropRateCommC: UInt16
        let errorsComm: UInt16
        let errorsCount1: UInt16
        let errorsCount2: UInt16
        let errorsCount3: UInt16
        let errorsCount4: UInt16
        let batteryRemainingPct: Int8
    }

    struct BatteryStatus {
        let currentConsumedMah: Int32
        let energyConsumedHj: Int32
        let temperatureCdeg: Int16
        let voltagesMv: [UInt16]   // 10 cells, 0xFFFF = unused
        let currentBatteryCa: Int16
        let id: UInt8
        let batteryFunction: UInt8
        let type: UInt8
        let batteryRemainingPct: Int8
    }

    struct CommandAck {
        let command: UInt16
        let result: UInt8
        let progress: UInt8
        let resultParam2: Int32
        let targetSystem: UInt8
        let targetComponent: UInt8
    }
}

enum ParsedMessage {
    case heartbeat(MAVMessages.Heartbeat)
    case globalPositionInt(MAVMessages.GlobalPositionInt)
    case attitude(MAVMessages.Attitude)
    case gpsRawInt(MAVMessages.GpsRawInt)
    case sysStatus(MAVMessages.SysStatus)
    case batteryStatus(MAVMessages.BatteryStatus)
    case commandAck(MAVMessages.CommandAck)
    case unknown(msgId: UInt32, payload: [UInt8])
}

// MARK: - Codec

enum MAVLinkCodec {
    static let stxV2: UInt8 = 0xFD

    /// Find and parse the next complete frame in [buffer] starting at
    /// [offset]. Returns the parsed message and the number of bytes
    /// consumed (so the caller can drop them from the rolling buffer).
    /// Returns nil if no complete frame is available yet.
    /// Caller is responsible for buffering across recv() boundaries.
    static func parseFrame(_ buffer: [UInt8], offset: Int) -> (ParsedMessage, Int)? {
        var i = offset
        // Skip up to the next STX. Pre-amble garbage gets dropped here.
        while i < buffer.count && buffer[i] != stxV2 { i += 1 }
        guard i + 10 <= buffer.count else { return nil } // need header + at least 2 CRC
        let len = Int(buffer[i + 1])
        let incompat = buffer[i + 2]
        let totalLen = 10 + len + 2 + (incompat & 0x01 != 0 ? 13 : 0)
        guard i + totalLen <= buffer.count else { return nil }
        if incompat & 0x01 != 0 {
            // Signed frame — we don't support signing yet. Drop and
            // advance past it so the buffer doesn't stall.
            return (.unknown(msgId: 0, payload: []), (i - offset) + totalLen)
        }
        let seq = buffer[i + 4]
        let sysId = buffer[i + 5]
        let compId = buffer[i + 6]
        _ = (seq, sysId, compId)
        let msgId = UInt32(buffer[i + 7]) | (UInt32(buffer[i + 8]) << 8) | (UInt32(buffer[i + 9]) << 16)
        let payloadStart = i + 10
        let payloadEnd = payloadStart + len
        let rxCrc = UInt16(buffer[payloadEnd]) | (UInt16(buffer[payloadEnd + 1]) << 8)

        // Compute CRC over LEN..PAYLOAD + CRC_EXTRA (if we know it).
        guard let msg = MAVMsg(rawValue: msgId) else {
            return (.unknown(msgId: msgId, payload: Array(buffer[payloadStart..<payloadEnd])),
                    (i - offset) + totalLen)
        }
        var crc: UInt16 = 0xFFFF
        for j in (i + 1)..<payloadEnd { crc = x25Acc(byte: buffer[j], crc: crc) }
        crc = x25Acc(byte: msg.crcExtra, crc: crc)
        guard crc == rxCrc else { return ((i - offset) + totalLen) > 0
            ? (.unknown(msgId: msgId, payload: []), (i - offset) + totalLen)
            : nil
        }

        // Zero-pad truncated payload back to wire length.
        var payload = Array(buffer[payloadStart..<payloadEnd])
        if payload.count < msg.wireLength {
            payload.append(contentsOf: repeatElement(UInt8(0), count: msg.wireLength - payload.count))
        }
        let parsed = decode(msg: msg, payload: payload)
        return (parsed, (i - offset) + totalLen)
    }

    /// Build a wire-format MAVLink 2 frame for a HEARTBEAT (we send
    /// these so the autopilot considers us alive) or a COMMAND_LONG
    /// (arm/disarm/takeoff/RTL).
    static func encodeHeartbeat(seq: UInt8, sysId: UInt8 = 255, compId: UInt8 = 0) -> [UInt8] {
        // GCS heartbeat: type=MAV_TYPE_GCS(6), autopilot=MAV_AUTOPILOT_INVALID(8),
        // base_mode=0, custom_mode=0, system_status=MAV_STATE_ACTIVE(4), version=3.
        var payload: [UInt8] = []
        payload.append(contentsOf: leBytes(UInt32(0)))     // custom_mode
        payload.append(6)                                   // type = GCS
        payload.append(8)                                   // autopilot = INVALID (GCS)
        payload.append(0)                                   // base_mode
        payload.append(4)                                   // system_status = ACTIVE
        payload.append(3)                                   // mavlink_version
        return finalizeFrame(msg: .heartbeat, payload: payload, seq: seq, sysId: sysId, compId: compId)
    }

    static func encodeCommandLong(
        seq: UInt8,
        sysId: UInt8 = 255,
        compId: UInt8 = 0,
        targetSystem: UInt8,
        targetComponent: UInt8,
        command: UInt16,
        params: [Float] = Array(repeating: 0, count: 7),
        confirmation: UInt8 = 0
    ) -> [UInt8] {
        precondition(params.count == 7)
        var payload: [UInt8] = []
        for p in params { payload.append(contentsOf: leBytes(p)) } // 7 × f32
        payload.append(contentsOf: leBytes(command))                // u16
        payload.append(targetSystem)
        payload.append(targetComponent)
        payload.append(confirmation)
        return finalizeFrame(msg: .commandLong, payload: payload, seq: seq, sysId: sysId, compId: compId)
    }

    // MARK: - Private

    private static func finalizeFrame(
        msg: MAVMsg,
        payload rawPayload: [UInt8],
        seq: UInt8,
        sysId: UInt8,
        compId: UInt8
    ) -> [UInt8] {
        // MAVLink 2 trailing-zero truncation.
        var payload = rawPayload
        while payload.count > 1, payload.last == 0 { payload.removeLast() }

        let msgId = msg.rawValue
        var frame: [UInt8] = []
        frame.reserveCapacity(12 + payload.count)
        frame.append(stxV2)
        frame.append(UInt8(payload.count))
        frame.append(0)                    // incompat_flags
        frame.append(0)                    // compat_flags
        frame.append(seq)
        frame.append(sysId)
        frame.append(compId)
        frame.append(UInt8(msgId & 0xFF))
        frame.append(UInt8((msgId >> 8) & 0xFF))
        frame.append(UInt8((msgId >> 16) & 0xFF))
        frame.append(contentsOf: payload)

        var crc: UInt16 = 0xFFFF
        for j in 1..<frame.count { crc = x25Acc(byte: frame[j], crc: crc) }
        crc = x25Acc(byte: msg.crcExtra, crc: crc)
        frame.append(UInt8(crc & 0xFF))
        frame.append(UInt8((crc >> 8) & 0xFF))
        return frame
    }

    /// CRC-16/MCRF4XX one-byte accumulator (a.k.a. X.25). Matches
    /// pymavlink's `x25_crc_accumulate`.
    private static func x25Acc(byte: UInt8, crc: UInt16) -> UInt16 {
        var tmp = UInt16(byte) ^ (crc & 0xFF)
        tmp = (tmp ^ (tmp << 4)) & 0xFF
        return ((crc >> 8) & 0xFF) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)
    }

    // MARK: - Payload decoders

    private static func decode(msg: MAVMsg, payload p: [UInt8]) -> ParsedMessage {
        switch msg {
        case .heartbeat:
            return .heartbeat(.init(
                customMode: leU32(p, 0),
                type: p[4],
                autopilot: p[5],
                baseMode: p[6],
                systemStatus: p[7],
                mavlinkVersion: p[8]
            ))
        case .globalPositionInt:
            return .globalPositionInt(.init(
                timeBootMs: leU32(p, 0),
                latDegE7: leI32(p, 4),
                lonDegE7: leI32(p, 8),
                altMslMm: leI32(p, 12),
                altAglMm: leI32(p, 16),
                vxCmS: leI16(p, 20),
                vyCmS: leI16(p, 22),
                vzCmS: leI16(p, 24),
                hdgCdeg: leU16(p, 26)
            ))
        case .attitude:
            return .attitude(.init(
                timeBootMs: leU32(p, 0),
                roll: leF32(p, 4),
                pitch: leF32(p, 8),
                yaw: leF32(p, 12),
                rollSpeed: leF32(p, 16),
                pitchSpeed: leF32(p, 20),
                yawSpeed: leF32(p, 24)
            ))
        case .gpsRawInt:
            return .gpsRawInt(.init(
                timeUsec: leU64(p, 0),
                latDegE7: leI32(p, 8),
                lonDegE7: leI32(p, 12),
                altMslMm: leI32(p, 16),
                eph: leU16(p, 20),
                epv: leU16(p, 22),
                velCmS: leU16(p, 24),
                cogCdeg: leU16(p, 26),
                fixType: p[28],
                satellitesVisible: p[29]
            ))
        case .sysStatus:
            return .sysStatus(.init(
                sensorsPresent: leU32(p, 0),
                sensorsEnabled: leU32(p, 4),
                sensorsHealth: leU32(p, 8),
                load: leU16(p, 12),
                voltageBatteryMv: leU16(p, 14),
                currentBatteryCa: leI16(p, 16),
                dropRateCommC: leU16(p, 18),
                errorsComm: leU16(p, 20),
                errorsCount1: leU16(p, 22),
                errorsCount2: leU16(p, 24),
                errorsCount3: leU16(p, 26),
                errorsCount4: leU16(p, 28),
                batteryRemainingPct: Int8(bitPattern: p[30])
            ))
        case .batteryStatus:
            var voltages = [UInt16]()
            for k in 0..<10 { voltages.append(leU16(p, 8 + k * 2)) }
            return .batteryStatus(.init(
                currentConsumedMah: leI32(p, 0),
                energyConsumedHj: leI32(p, 4),
                temperatureCdeg: leI16(p, 28),
                voltagesMv: voltages,
                currentBatteryCa: leI16(p, 30),
                id: p[32],
                batteryFunction: p[33],
                type: p[34],
                batteryRemainingPct: Int8(bitPattern: p[35])
            ))
        case .commandAck:
            return .commandAck(.init(
                command: leU16(p, 0),
                result: p[2],
                progress: p.count > 3 ? p[3] : 0,
                resultParam2: p.count >= 8 ? leI32(p, 4) : 0,
                targetSystem: p.count > 8 ? p[8] : 0,
                targetComponent: p.count > 9 ? p[9] : 0
            ))
        case .commandLong:
            return .unknown(msgId: msg.rawValue, payload: p)
        }
    }

    // MARK: - Little-endian readers / writers

    private static func leU16(_ p: [UInt8], _ o: Int) -> UInt16 {
        UInt16(p[o]) | (UInt16(p[o + 1]) << 8)
    }
    private static func leI16(_ p: [UInt8], _ o: Int) -> Int16 {
        Int16(bitPattern: leU16(p, o))
    }
    private static func leU32(_ p: [UInt8], _ o: Int) -> UInt32 {
        UInt32(p[o]) | (UInt32(p[o + 1]) << 8) | (UInt32(p[o + 2]) << 16) | (UInt32(p[o + 3]) << 24)
    }
    private static func leI32(_ p: [UInt8], _ o: Int) -> Int32 {
        Int32(bitPattern: leU32(p, o))
    }
    private static func leU64(_ p: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(p[o + k]) << (8 * k) }
        return v
    }
    private static func leF32(_ p: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: leU32(p, o))
    }

    private static func leBytes(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }
    private static func leBytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private static func leBytes(_ v: Float) -> [UInt8] {
        leBytes(v.bitPattern)
    }
}
