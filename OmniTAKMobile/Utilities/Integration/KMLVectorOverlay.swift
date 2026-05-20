//
//  KMLVectorOverlay.swift
//  OmniTAKMobile
//
//  Robust large-KML overlay support. The legacy KMLOverlayManager turned
//  every placemark into an individual MapKit/Mapbox annotation — which
//  collapses (and crashes) at tens of thousands of features, the same way
//  competitors do. This path instead streams a KML into a single GeoJSON
//  file on disk and renders it as ONE Mapbox GeoJSONSource + vector layers,
//  which the GPU handles at 50k+ features without breaking a sweat.
//
//  Flow: import → parse (off-thread) → stream to <id>.geojson → register a
//  lightweight overlay record → the map adds a GeoJSONSource(.url) + line /
//  fill / circle layers. Toggling is a layer-visibility flip (instant), and
//  the parsed GeoJSON persists so relaunch never re-parses the source KML.
//

import Foundation

// MARK: - Overlay record

/// Lightweight metadata for one imported KML overlay. The heavy geometry
/// lives in the on-disk `.geojson`; this is all that's kept in memory /
/// persisted.
struct KMLVectorOverlay: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    /// File name (relative to the overlays directory) of the GeoJSON.
    var fileName: String
    /// Line/stroke color as a hex string (e.g. "#A78BFA").
    var colorHex: String
    var visible: Bool
    var featureCount: Int
    // Bounding box for "zoom to fit".
    var minLat: Double
    var minLon: Double
    var maxLat: Double
    var maxLon: Double
}

// MARK: - Streaming KML → GeoJSON exporter

enum KMLGeoJSONExporter {
    struct Result: Sendable {
        let featureCount: Int
        let minLat: Double
        let minLon: Double
        let maxLat: Double
        let maxLon: Double
    }

    enum ExportError: Error { case noFeatures, fileHandle }

    /// Stream `document` to a GeoJSON FeatureCollection at `url`. Writes
    /// incrementally through a 64 KB buffer so a 50k-feature document never
    /// materializes as one giant in-memory string. Returns the feature count
    /// and bounding box. Safe to call off the main thread.
    static func export(document: KMLDocument, to url: URL) throws -> Result {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { throw ExportError.fileHandle }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        func flush() {
            if !buffer.isEmpty { try? handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        func emit(_ s: String) {
            buffer.append(contentsOf: s.utf8)
            if buffer.count >= (1 << 16) { flush() }
        }

        var count = 0
        var minLat = 90.0, minLon = 180.0, maxLat = -90.0, maxLon = -180.0
        func track(_ lat: Double, _ lon: Double) {
            if lat < minLat { minLat = lat }; if lat > maxLat { maxLat = lat }
            if lon < minLon { minLon = lon }; if lon > maxLon { maxLon = lon }
        }
        func coord(_ p: KMLPoint) -> String { "[\(fmt(p.longitude)),\(fmt(p.latitude))]" }

        func writeFeatureHeader(_ name: String) {
            if count > 0 { emit(",") }
            emit("{\"type\":\"Feature\",\"properties\":{\"name\":\(jsonString(name))},\"geometry\":")
        }

        func write(_ geometry: KMLGeometry, name: String) {
            switch geometry {
            case .point(let pt):
                writeFeatureHeader(name)
                emit("{\"type\":\"Point\",\"coordinates\":\(coord(pt))}}")
                track(pt.latitude, pt.longitude)
                count += 1
            case .lineString(let line):
                guard line.coordinates.count >= 2 else { return }
                writeFeatureHeader(name)
                emit("{\"type\":\"LineString\",\"coordinates\":[")
                for (i, pt) in line.coordinates.enumerated() {
                    if i > 0 { emit(",") }
                    emit(coord(pt)); track(pt.latitude, pt.longitude)
                }
                emit("]}}")
                count += 1
            case .polygon(let poly):
                guard poly.outerBoundary.count >= 3 else { return }
                writeFeatureHeader(name)
                emit("{\"type\":\"Polygon\",\"coordinates\":[[")
                for (i, pt) in poly.outerBoundary.enumerated() {
                    if i > 0 { emit(",") }
                    emit(coord(pt)); track(pt.latitude, pt.longitude)
                }
                emit("]")
                for ring in poly.innerBoundaries where ring.count >= 3 {
                    emit(",[")
                    for (i, pt) in ring.enumerated() {
                        if i > 0 { emit(",") }
                        emit(coord(pt))
                    }
                    emit("]")
                }
                emit("]}}")
                count += 1
            case .multiGeometry(let geoms):
                for sub in geoms { write(sub, name: name) }
            }
        }

        emit("{\"type\":\"FeatureCollection\",\"features\":[")
        for placemark in document.placemarks { write(placemark.geometry, name: placemark.name) }
        for folder in document.folders {
            for placemark in folder.placemarks { write(placemark.geometry, name: placemark.name) }
        }
        emit("]}")
        flush()

        guard count > 0 else { throw ExportError.noFeatures }
        return Result(featureCount: count, minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
    }

    /// 6-decimal coordinates (~0.1 m) — plenty for tactical overlays and a
    /// big file-size win over full Double precision.
    private static func fmt(_ d: Double) -> String { String(format: "%.6f", d) }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n", "\r", "\t": out += " "
            default:
                if ch.value < 0x20 { out += " " } else { out.unicodeScalars.append(ch) }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - Store

/// Owns the set of imported vector overlays + their persisted metadata.
@MainActor
final class KMLVectorOverlayStore: ObservableObject {
    static let shared = KMLVectorOverlayStore()

    @Published private(set) var overlays: [KMLVectorOverlay] = []
    @Published var isImporting = false
    @Published var importStatus: String = ""
    @Published var lastError: String?

    private let dir: URL
    private let metaURL: URL

    private static let palette = ["#A78BFA", "#5AC8FA", "#34C759", "#FF9F0A", "#FF375F", "#FFD60A"]

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("KMLOverlays", isDirectory: true)
        metaURL = dir.appendingPathComponent("overlays.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    func fileURL(_ overlay: KMLVectorOverlay) -> URL { dir.appendingPathComponent(overlay.fileName) }

    /// Import a `.kml`/`.kmz` file: parse + stream to GeoJSON off the main
    /// thread, then register the overlay.
    func importKML(from url: URL) async {
        isImporting = true
        lastError = nil
        importStatus = "Reading file…"
        let displayName = url.deletingPathExtension().lastPathComponent
        let sourceName = url.lastPathComponent
        let id = UUID().uuidString
        let geoName = "\(id).geojson"
        let outURL = dir.appendingPathComponent(geoName)

        do {
            let kmlData: Data
            if sourceName.lowercased().hasSuffix(".kmz") {
                let (data, _) = try KMZHandler.extractKML(from: url)
                kmlData = data
            } else {
                kmlData = try Data(contentsOf: url)
            }

            importStatus = "Parsing \(ByteCountFormatter.string(fromByteCount: Int64(kmlData.count), countStyle: .file))…"
            let result = try await Task.detached(priority: .userInitiated) {
                let parser = KMLParser(fileName: sourceName)
                let document = try parser.parse(data: kmlData)
                return try KMLGeoJSONExporter.export(document: document, to: outURL)
            }.value

            let overlay = KMLVectorOverlay(
                id: id,
                name: displayName,
                fileName: geoName,
                colorHex: Self.palette[overlays.count % Self.palette.count],
                visible: true,
                featureCount: result.featureCount,
                minLat: result.minLat, minLon: result.minLon,
                maxLat: result.maxLat, maxLon: result.maxLon
            )
            overlays.append(overlay)
            persist()
            importStatus = "Imported \(result.featureCount) features"
            isImporting = false
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            lastError = (error as? KMLGeoJSONExporter.ExportError) == .noFeatures
                ? "No map features found in that file."
                : "Import failed: \(error.localizedDescription)"
            importStatus = ""
            isImporting = false
        }
    }

    func setVisible(_ id: String, _ visible: Bool) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[idx].visible = visible
        persist()
    }

    func setColor(_ id: String, hex: String) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[idx].colorHex = hex
        persist()
    }

    func remove(_ id: String) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: fileURL(overlays[idx]))
        overlays.remove(at: idx)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overlays) else { return }
        try? data.write(to: metaURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode([KMLVectorOverlay].self, from: data) else { return }
        // Drop any overlays whose GeoJSON file went missing.
        overlays = decoded.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path) }
    }
}
