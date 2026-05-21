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
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

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

    /// Import a GeoTIFF — parse the geo-tags for the corner box, decode the
    /// raster (ImageIO) to PNG, and register it as a raster overlay. Returns
    /// false if the TIFF isn't georeferenced (so the caller can report it).
    @discardableResult
    func importGeoTIFF(from url: URL) async -> Bool {
        isImporting = true; lastError = nil; importStatus = "Reading GeoTIFF…"
        do {
            let data = try Data(contentsOf: url)
            guard let box = GeoTIFFImporter.geoBounds(from: data) else {
                lastError = "That TIFF isn't georeferenced (no GeoTIFF tags), or its projection isn't supported (WGS84 / Web Mercator only)."
                importStatus = ""; isImporting = false
                return false
            }
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw RasterError.missingImage
            }
            let id = UUID().uuidString
            let fileName = "\(id).png"
            let outURL = dir.appendingPathComponent(fileName)
            guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw RasterError.missingImage
            }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { throw RasterError.missingImage }
            overlays.append(RasterOverlay(
                id: id, name: url.deletingPathExtension().lastPathComponent, fileName: fileName,
                north: box.north, south: box.south, east: box.east, west: box.west
            ))
            persist()
            importStatus = "Imported GeoTIFF"
            isImporting = false
            return true
        } catch {
            lastError = "GeoTIFF import failed: \(error.localizedDescription)"
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

// MARK: - GeoTIFF geo-tag reader

/// Minimal GeoTIFF reader: parses the TIFF IFD for the georeferencing tags
/// (ModelPixelScale 33550 + ModelTiepoint 33922, or ModelTransformation 34264)
/// and the CRS (GeoKeyDirectory 34735), and returns the WGS84 corner box.
/// Supports EPSG:4326 (degrees) and EPSG:3857 (Web Mercator). Image decoding
/// is handled separately by ImageIO.
enum GeoTIFFImporter {
    struct Box { let north: Double; let south: Double; let east: Double; let west: Double }

    static func geoBounds(from data: Data) -> Box? {
        let b = [UInt8](data)
        guard b.count > 8 else { return nil }
        let little: Bool
        if b[0] == 0x49, b[1] == 0x49 { little = true }       // "II"
        else if b[0] == 0x4D, b[1] == 0x4D { little = false } // "MM"
        else { return nil }

        func u16(_ o: Int) -> Int {
            guard o + 1 < b.count else { return 0 }
            return little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])
        }
        func u32(_ o: Int) -> Int {
            guard o + 3 < b.count else { return 0 }
            return little
                ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
                : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        func f64(_ o: Int) -> Double {
            guard o + 7 < b.count else { return 0 }
            var u: UInt64 = 0
            for i in 0..<8 { u |= UInt64(b[o + (little ? i : 7 - i)]) << (8 * i) }
            return Double(bitPattern: u)
        }

        guard u16(2) == 42 else { return nil }   // TIFF magic
        let ifd = u32(4)
        guard ifd + 2 <= b.count else { return nil }
        let entries = u16(ifd)

        var width = 0, height = 0
        var pixelScale: [Double] = [], tiepoint: [Double] = [], transform: [Double] = []
        var geoKeys: [Int] = []
        let typeSizes = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]

        for e in 0..<entries {
            let off = ifd + 2 + e * 12
            guard off + 12 <= b.count else { break }
            let tag = u16(off), type = u16(off + 2), cnt = u32(off + 4)
            let tsize = type < typeSizes.count ? typeSizes[type] : 0
            let len = tsize * cnt
            let valOff = len <= 4 ? off + 8 : u32(off + 8)
            switch tag {
            case 256: width = type == 3 ? u16(off + 8) : u32(off + 8)
            case 257: height = type == 3 ? u16(off + 8) : u32(off + 8)
            case 33550: pixelScale = (0..<cnt).map { f64(valOff + $0 * 8) }
            case 33922: tiepoint = (0..<cnt).map { f64(valOff + $0 * 8) }
            case 34264: transform = (0..<cnt).map { f64(valOff + $0 * 8) }
            case 34735: geoKeys = (0..<cnt).map { u16(valOff + $0 * 2) }
            default: break
            }
        }
        guard width > 0, height > 0 else { return nil }

        // CRS: GeoKeyDirectory = header(4) then 4-short entries (key, loc, count, value).
        var epsg = 4326
        if geoKeys.count >= 4 {
            var i = 4
            for _ in 0..<geoKeys[3] {
                guard i + 3 < geoKeys.count else { break }
                let key = geoKeys[i], loc = geoKeys[i + 1], value = geoKeys[i + 3]
                if loc == 0 {
                    if key == 3072 { epsg = value }                 // ProjectedCSTypeGeoKey
                    else if key == 2048, epsg == 4326 { epsg = value } // GeographicTypeGeoKey
                }
                i += 4
            }
        }

        // Pixel→world origin + scale.
        var originX = 0.0, originY = 0.0, sx = 0.0, sy = 0.0
        if pixelScale.count >= 2, tiepoint.count >= 6 {
            sx = pixelScale[0]; sy = pixelScale[1]
            originX = tiepoint[3] - tiepoint[0] * sx
            originY = tiepoint[4] + tiepoint[1] * sy
        } else if transform.count >= 16 {
            originX = transform[3]; originY = transform[7]
            sx = transform[0]; sy = -transform[5]
        } else {
            return nil
        }

        let wX = originX, eX = originX + Double(width) * sx
        let nY = originY, sY = originY - Double(height) * sy

        func lonLat(_ x: Double, _ y: Double) -> (Double, Double) {
            if epsg == 3857 || epsg == 900913 || epsg == 102100 {
                let lon = x / 6378137.0 * 180.0 / .pi
                let lat = (2.0 * atan(exp(y / 6378137.0)) - .pi / 2.0) * 180.0 / .pi
                return (lon, lat)
            }
            return (x, y) // assume degrees (EPSG:4326)
        }
        let (west, north) = lonLat(wX, nY)
        let (east, south) = lonLat(eX, sY)
        guard abs(north) <= 90, abs(south) <= 90, abs(east) <= 180, abs(west) <= 180,
              north > south, east != west else { return nil }
        return Box(north: north, south: south, east: east, west: west)
    }
}
