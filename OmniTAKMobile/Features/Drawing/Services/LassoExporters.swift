//
//  LassoExporters.swift
//  OmniTAKMobile
//
//  Issue #16 — real exporters for the lasso selection. KML doc
//  writer + a TAK Mission Package zip writer + a CoT builder for
//  delete tombstones and dest-routed sends. Mirrors the Android
//  `LassoExporters.kt` / `CotBuilders.kt` shape so behaviour stays
//  in lockstep.
//
//  Outputs land in the app's tmp dir (`FileManager.temporaryDirectory`)
//  so the share sheet can hand them off via the standard
//  UIActivityViewController flow.
//

import CoreLocation
import Foundation

// MARK: - CoT builders

enum LassoCotBuilders {
    /// `t-x-d-d` "Tasking Delete Data" — the canonical TAK delete
    /// primitive. Server propagates to other EUDs which remove the
    /// target marker. Deleter UID goes in the event's `uid` field;
    /// the target UID lives on a `<link>` with `relation="p-p"`.
    static func buildDeleteEvent(targetUid: String, senderUid: String) -> String {
        let now = isoNow()
        let stale = isoOffset(60)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <event version="2.0" uid="\(xmlEscape(senderUid))" type="t-x-d-d" how="h-g-i-g-o"
               time="\(now)" start="\(now)" stale="\(stale)">
          <point lat="0.0" lon="0.0" hae="0.0" ce="9999999.0" le="9999999.0"/>
          <detail>
            <link uid="\(xmlEscape(targetUid))" relation="p-p"/>
            <__forcedelete/>
          </detail>
        </event>
        """
    }

    /// Re-emit a marker as a CoT event addressed to specific recipients
    /// via `<dest uid="..."/>` elements. The TAK server routes
    /// accordingly.
    static func rebuildEvent(
        uid: String,
        type: String,
        callsign: String?,
        coordinate: CLLocationCoordinate2D,
        remarks: String = "",
        destUids: [String]
    ) -> String {
        let now = isoNow()
        let stale = isoOffset(120)
        let dests = destUids.map { "<dest uid=\"\(xmlEscape($0))\"/>" }.joined()
        let callsignAttr = callsign.map { " callsign=\"\(xmlEscape($0))\"" } ?? ""
        let remarksTag = remarks.isEmpty ? "" : "<remarks>\(xmlEscape(remarks))</remarks>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <event version="2.0" uid="\(xmlEscape(uid))" type="\(xmlEscape(type))" how="h-g-i-g-o"
               time="\(now)" start="\(now)" stale="\(stale)">
          <point lat="\(coordinate.latitude)" lon="\(coordinate.longitude)" hae="0.0" ce="9999999.0" le="9999999.0"/>
          <detail>
            <contact\(callsignAttr)/>
            \(remarksTag)
            \(dests)
          </detail>
        </event>
        """
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func isoNow() -> String { isoFmt().string(from: Date()) }
    private static func isoOffset(_ seconds: TimeInterval) -> String {
        isoFmt().string(from: Date().addingTimeInterval(seconds))
    }
    private static func isoFmt() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }
}

// MARK: - Lasso export payload
//
// Identity-only shape with everything the exporters need so MapViewController
// can decouple "which models did the lasso hit" from "how do I serialize
// them." Each entry is a marker; drawings are deferred to a follow-up
// since the iOS lasso scope today only commits markers.

struct LassoExportMarker {
    let uid: String
    let type: String        // "a-f-G-U-C" / etc — drives KML style id
    let callsign: String?
    let coordinate: CLLocationCoordinate2D
    let remarks: String

    init(
        uid: String,
        type: String = "a-u-G",
        callsign: String? = nil,
        coordinate: CLLocationCoordinate2D,
        remarks: String = ""
    ) {
        self.uid = uid
        self.type = type
        self.callsign = callsign
        self.coordinate = coordinate
        self.remarks = remarks
    }
}

// MARK: - KML

enum LassoKMLBuilder {
    /// Build a KML 2.2 document, one Placemark per marker. Style ids
    /// follow MIL-STD affiliation ("friend"/"hostile"/"neutral"/"unknown")
    /// derived from the second token of the CoT type string.
    static func build(name: String, markers: [LassoExportMarker]) -> String {
        var sb = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        sb += "<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n"
        sb += "  <Document>\n"
        sb += "    <name>\(LassoCotBuilders.xmlEscape(name))</name>\n"
        sb += "    <description>Lasso selection exported from OmniTAK — \(markers.count) feature(s).</description>\n"
        sb += "    <Style id=\"friend\">  <IconStyle><color>ff00ff00</color><scale>1.1</scale></IconStyle></Style>\n"
        sb += "    <Style id=\"hostile\"> <IconStyle><color>ff0000ff</color><scale>1.1</scale></IconStyle></Style>\n"
        sb += "    <Style id=\"neutral\"> <IconStyle><color>ffff00ff</color><scale>1.1</scale></IconStyle></Style>\n"
        sb += "    <Style id=\"unknown\"> <IconStyle><color>ff00ffff</color><scale>1.1</scale></IconStyle></Style>\n"
        for m in markers {
            let styleId = affiliationCode(for: m.type)
            let nm = m.callsign?.trimmingCharacters(in: .whitespaces).isEmpty == false ? m.callsign! : m.uid
            sb += "    <Placemark>\n"
            sb += "      <name>\(LassoCotBuilders.xmlEscape(nm))</name>\n"
            sb += "      <styleUrl>#\(styleId)</styleUrl>\n"
            if !m.remarks.isEmpty {
                sb += "      <description>\(LassoCotBuilders.xmlEscape(m.remarks))</description>\n"
            }
            sb += "      <ExtendedData>\n"
            sb += "        <Data name=\"uid\"><value>\(LassoCotBuilders.xmlEscape(m.uid))</value></Data>\n"
            sb += "        <Data name=\"type\"><value>\(LassoCotBuilders.xmlEscape(m.type))</value></Data>\n"
            sb += "      </ExtendedData>\n"
            sb += "      <Point><coordinates>\(m.coordinate.longitude),\(m.coordinate.latitude),0</coordinates></Point>\n"
            sb += "    </Placemark>\n"
        }
        sb += "  </Document>\n</kml>\n"
        return sb
    }

    /// Write the KML to a temp file and return the URL — caller hands
    /// it to a UIActivityViewController for sharing.
    static func write(name: String, markers: [LassoExportMarker]) throws -> URL {
        let kml = build(name: name, markers: markers)
        let url = exportsDir().appendingPathComponent("lasso-\(stamp()).kml")
        try kml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func affiliationCode(for type: String) -> String {
        // CoT type encodes affiliation as the 2nd token: a-f-…, a-h-…, etc.
        let parts = type.split(separator: "-")
        guard parts.count >= 2 else { return "unknown" }
        return switch parts[1].first {
        case "f"?: "friend"
        case "h"?: "hostile"
        case "n"?: "neutral"
        default: "unknown"
        }
    }
}

// MARK: - Mission Package zip

enum LassoMissionPackageBuilder {
    /// Build a TAK Mission Package (zip with MANIFEST/manifest.xml +
    /// one `cot/<uid>.cot` per marker). Returns the URL of the zip on
    /// disk; throws if zip serialization fails.
    static func build(name: String, markers: [LassoExportMarker]) throws -> URL {
        let pkgUid = UUID().uuidString
        let outUrl = exportsDir().appendingPathComponent("lasso-\(stamp()).zip")

        // Build the entries first, then have ZipWriter pack them.
        let manifest = buildManifest(pkgUid: pkgUid, name: name, markers: markers)
        var entries: [(name: String, data: Data)] = [
            ("MANIFEST/manifest.xml", Data(manifest.utf8))
        ]
        for m in markers {
            let safe = m.uid.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            let cot = LassoCotBuilders.rebuildEvent(
                uid: m.uid, type: m.type, callsign: m.callsign,
                coordinate: m.coordinate, remarks: m.remarks, destUids: []
            )
            entries.append(("cot/\(safe).cot", Data(cot.utf8)))
        }

        let zipBytes = LassoZipWriter.write(entries: entries)
        try zipBytes.write(to: outUrl, options: .atomic)
        return outUrl
    }

    private static func buildManifest(pkgUid: String, name: String, markers: [LassoExportMarker]) -> String {
        var sb = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        sb += "<MissionPackageManifest version=\"2\">\n"
        sb += "  <Configuration>\n"
        sb += "    <Parameter name=\"uid\" value=\"\(LassoCotBuilders.xmlEscape(pkgUid))\"/>\n"
        sb += "    <Parameter name=\"name\" value=\"\(LassoCotBuilders.xmlEscape(name))\"/>\n"
        sb += "    <Parameter name=\"onReceiveImport\" value=\"true\"/>\n"
        sb += "    <Parameter name=\"onReceiveDelete\" value=\"false\"/>\n"
        sb += "  </Configuration>\n"
        sb += "  <Contents>\n"
        for m in markers {
            let safe = m.uid.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            sb += "    <Content ignore=\"false\" zipEntry=\"cot/\(safe).cot\">\n"
            sb += "      <Parameter name=\"uid\" value=\"\(LassoCotBuilders.xmlEscape(m.uid))\"/>\n"
            sb += "      <Parameter name=\"name\" value=\"\(LassoCotBuilders.xmlEscape(m.callsign ?? m.uid))\"/>\n"
            sb += "    </Content>\n"
        }
        sb += "  </Contents>\n</MissionPackageManifest>\n"
        return sb
    }
}

// MARK: - Shared helpers

private func exportsDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-exports", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date())
}
