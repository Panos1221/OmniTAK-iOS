//
//  GybDetectionParser.swift
//  OmniTAKMobile
//
//  Parses the newline-delimited JSON the gyb_detect ESP32 streams over BLE
//  GATT into the SAME `OpenDroneIdMessage` shapes the on-device FAA Remote ID
//  scanner produces. Feeding gyb detections through the existing
//  `RemoteIdTrackStore` means a drone seen over WiFi by the gyb AND over BLE
//  by the phone collapses to one `RID-{uasId}` track — automatic dedup.
//
//  The gyb is the WiFi-beacon Remote ID path the phone physically cannot do
//  (iOS/Android can't put WiFi into monitor mode). The phone keeps catching
//  the Bluetooth Remote ID subset directly; the gyb fills the WiFi gap and
//  ships it over Bluetooth so the gyb's WiFi radio stays free for scanning.
//
//  Wire contract: src/gatt_link.h + src/main.cpp send_json() in ghostnet-fw,
//  and tools/mock_gyb_peripheral.py. Keep the field set in lockstep.
//

import Foundation

enum GybMessage: Equatable {
    /// Sent once when a phone connects — make/model/serial/capabilities.
    case deviceInfo(model: String, serialNumber: String, version: String)
    /// Sent every 5 s. Level is 0…1.
    case battery(level: Double)
    /// One drone detection — decoded to BasicID (+ Location when GPS is
    /// valid) so it slots straight into `RemoteIdTrackStore.ingest`.
    case drone(uasId: String, messages: [OpenDroneIdMessage], recvMethod: Int)
}

enum GybDetectionParser {

    /// Parse one JSON object (one line off the GATT stream). Returns nil for
    /// unrecognised / malformed lines (consumers fail soft, never crash).
    static func parse(_ line: String) -> GybMessage? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Battery status — distinct by its batteryLevel key.
        if let level = doubleValue(obj["batteryLevel"]) {
            return .battery(level: level)
        }

        // Drone detection — distinct by uasId.
        if obj["uasId"] != nil {
            return parseDrone(obj)
        }

        // Device info — make/model handshake (no uasId, no batteryLevel).
        if obj["model"] != nil || obj["manufacturer"] != nil {
            return .deviceInfo(
                model: stringValue(obj["model"]) ?? "gyb_detect",
                serialNumber: stringValue(obj["serialNumber"]) ?? "",
                version: stringValue(obj["version"]) ?? ""
            )
        }

        return nil
    }

    // MARK: - Drone

    private static func parseDrone(_ obj: [String: Any]) -> GybMessage? {
        let mac = stringValue(obj["uasId"]) ?? ""
        let serial = stringValue(obj["serialNumber"]) ?? ""
        let recvMethod = intValue(obj["recvMethod"]) ?? 0

        // Key the track by the drone serial when present so a WiFi (gyb) and
        // BLE (phone) sighting of the same aircraft share one `RID-` UID;
        // fall back to the MAC the firmware puts in uasId otherwise.
        let key = !serial.isEmpty ? serial : mac
        guard !key.isEmpty else { return nil }

        let uaType = OpenDroneIdMessage.UaType.from(code: intValue(obj["uasType"]) ?? 0)
        let idType: OpenDroneIdMessage.IdType = serial.isEmpty ? .none : .serialNumber

        var messages: [OpenDroneIdMessage] = [
            .basicId(protocolVersion: 0, idType: idType, uaType: uaType, uasId: key)
        ]

        // Firmware omits uasLat/uasLon entirely when GPS is invalid; only
        // build a Location when both are present and sane.
        if let lat = doubleValue(obj["uasLat"]), let lon = doubleValue(obj["uasLon"]),
           !(lat == 0 && lon == 0), !lat.isNaN, !lon.isNaN {
            let loc = OpenDroneIdMessage.Location(
                protocolVersion: 0,
                operationalStatus: .from(code: intValue(obj["opStatus"]) ?? 0),
                heightType: .aboveGroundLevel,
                trackDirectionDeg: intValue(obj["uasHeading"]) ?? 0,
                groundSpeedMs: doubleValue(obj["uasHSpeed"]) ?? 0,
                verticalSpeedMs: doubleValue(obj["uasVSpeed"]) ?? 0,
                latitude: lat,
                longitude: lon,
                pressureAltitudeM: doubleValue(obj["uasBaroPressure"]),
                geodeticAltitudeM: doubleValue(obj["uasHae"]),
                heightAboveTakeoffM: doubleValue(obj["uasHag"]),
                horizontalAccuracyM: doubleValue(obj["uasHorizontalError"]),
                verticalAccuracyM: doubleValue(obj["uasVerticalError"]),
                timestampSec: nil
            )
            messages.append(.location(loc))
        }

        return .drone(uasId: key, messages: messages, recvMethod: recvMethod)
    }

    /// Human-readable detection method for remarks.
    static func recvMethodLabel(_ code: Int) -> String {
        switch code {
        case 1: return "WiFi beacon"
        case 2: return "WiFi NAN"
        case 16: return "Bluetooth"
        default: return "unknown"
        }
    }

    // MARK: - Lenient coercion (firmware sends some numbers as strings)

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        // Firmware sends lat/lon as space-padded strings (dtostrf, e.g.
        // "  47.658800"). Swift's Double(_:) — unlike Kotlin's
        // toDoubleOrNull — does NOT trim, so we must, or the location is
        // silently dropped and the track never gets a marker.
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return Int(t) ?? Double(t).map(Int.init)
        }
        return nil
    }
}
