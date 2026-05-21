//
//  RasterOverlay.swift
//  OmniTAKMobile
//
//  Georeferenced raster/imagery overlays (KMZ/KML GroundOverlay now; GeoTIFF,
//  MBTiles, GeoPDF to follow). Each overlay is a single image placed on the
//  map by its geographic corner box and rendered as a Mapbox ImageSource +
//  RasterLayer — the raster sibling of the KML vector overlay path.
//

import Foundation

// MARK: - Overlay record

struct RasterOverlay: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    /// Image file name (relative to the raster overlays directory).
    var fileName: String
    /// Geographic corner box (WGS84).
    var north: Double
    var south: Double
    var east: Double
    var west: Double
    /// LatLonBox rotation in degrees (CCW about center). 0 for most overlays.
    var rotation: Double
    var opacity: Double
    var visible: Bool
    var createdAt: Date

    init(id: String, name: String, fileName: String, north: Double, south: Double,
         east: Double, west: Double, rotation: Double = 0, opacity: Double = 0.85,
         visible: Bool = true, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.fileName = fileName
        self.north = north; self.south = south; self.east = east; self.west = west
        self.rotation = rotation; self.opacity = opacity; self.visible = visible
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decode(String.self, forKey: .fileName)
        north = try c.decode(Double.self, forKey: .north)
        south = try c.decode(Double.self, forKey: .south)
        east = try c.decode(Double.self, forKey: .east)
        west = try c.decode(Double.self, forKey: .west)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.85
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

// MARK: - GroundOverlay parser

/// Extracts `<GroundOverlay>` records (image href + LatLonBox) from KML.
final class GroundOverlayParser: NSObject, XMLParserDelegate {
    struct Item { var name = "GroundOverlay"; var href = ""; var north = 0.0; var south = 0.0; var east = 0.0; var west = 0.0; var rotation = 0.0 }

    private var items: [Item] = []
    private var current: Item?
    private var inGroundOverlay = false
    private var inLatLonBox = false
    private var inIcon = false
    private var text = ""

    func parse(_ data: Data) -> [Item] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        switch name {
        case "GroundOverlay": inGroundOverlay = true; current = Item()
        case "Icon": inIcon = true
        case "LatLonBox", "LatLonAltBox": inLatLonBox = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "GroundOverlay":
            if let c = current { items.append(c) }
            current = nil; inGroundOverlay = false
        case "Icon": inIcon = false
        case "LatLonBox", "LatLonAltBox": inLatLonBox = false
        case "name" where inGroundOverlay && !inLatLonBox && !inIcon:
            if !value.isEmpty { current?.name = value }
        case "href" where inIcon:
            current?.href = value
        case "north" where inLatLonBox: current?.north = Double(value) ?? 0
        case "south" where inLatLonBox: current?.south = Double(value) ?? 0
        case "east" where inLatLonBox: current?.east = Double(value) ?? 0
        case "west" where inLatLonBox: current?.west = Double(value) ?? 0
        case "rotation" where inLatLonBox: current?.rotation = Double(value) ?? 0
        default: break
        }
        text = ""
    }
}

// MARK: - Store

@MainActor
final class RasterOverlayStore: ObservableObject {
    static let shared = RasterOverlayStore()

    @Published private(set) var overlays: [RasterOverlay] = []
    @Published var isImporting = false
    @Published var importStatus = ""
    @Published var lastError: String?

    private let dir: URL
    private let metaURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("RasterOverlays", isDirectory: true)
        metaURL = dir.appendingPathComponent("rasters.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    func imageURL(_ overlay: RasterOverlay) -> URL { dir.appendingPathComponent(overlay.fileName) }

    enum RasterError: Error { case noGroundOverlay, missingImage }

    /// Import KMZ/KML GroundOverlay(s) — extracts the bundled image and the
    /// LatLonBox. KMZ is required for the image to travel with the file.
    /// Returns true if it handled the file as imagery; false means "no
    /// GroundOverlay here" so the caller can fall back to vector KML import.
    @discardableResult
    func importGroundOverlay(from url: URL) async -> Bool {
        isImporting = true; lastError = nil; importStatus = "Reading file…"
        do {
            let (kmlData, resources) = try KMZHandler.extractKML(from: url)
            let items = GroundOverlayParser().parse(kmlData)
            // Not imagery — let the caller try a vector KML import instead.
            guard !items.isEmpty else { isImporting = false; importStatus = ""; return false }

            var added = 0
            for item in items {
                // Match the href against the bundled resources (KMZ paths can
                // be relative with ./ or subfolders).
                let key = item.href
                let last = (key as NSString).lastPathComponent
                guard let imgData = resources[key] ?? resources[last]
                        ?? resources.first(where: { $0.key.hasSuffix(last) })?.value
                else { continue }

                let id = UUID().uuidString
                let ext = (last as NSString).pathExtension.isEmpty ? "png" : (last as NSString).pathExtension
                let fileName = "\(id).\(ext)"
                try imgData.write(to: dir.appendingPathComponent(fileName))
                overlays.append(RasterOverlay(
                    id: id, name: item.name, fileName: fileName,
                    north: item.north, south: item.south, east: item.east, west: item.west,
                    rotation: item.rotation
                ))
                added += 1
            }
            guard added > 0 else { throw RasterError.missingImage }
            persist()
            importStatus = "Imported \(added) image overlay\(added == 1 ? "" : "s")"
            isImporting = false
            return true
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
            importStatus = ""; isImporting = false
            return false
        }
    }

    func setVisible(_ id: String, _ visible: Bool) { mutate(id) { $0.visible = visible } }
    func setOpacity(_ id: String, _ value: Double) { mutate(id) { $0.opacity = min(max(value, 0.05), 1.0) } }
    func rename(_ id: String, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate(id) { $0.name = t }
    }

    func remove(_ id: String) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: imageURL(overlays[idx]))
        overlays.remove(at: idx); persist()
    }

    func removeAll() {
        for o in overlays { try? FileManager.default.removeItem(at: imageURL(o)) }
        overlays.removeAll(); persist()
    }

    private func mutate(_ id: String, _ change: (inout RasterOverlay) -> Void) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        change(&overlays[idx]); persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overlays) else { return }
        try? data.write(to: metaURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode([RasterOverlay].self, from: data) else { return }
        overlays = decoded.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path) }
    }
}
