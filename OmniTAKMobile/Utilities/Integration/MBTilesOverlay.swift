//
//  MBTilesOverlay.swift
//  OmniTAKMobile
//
//  MBTiles raster basemap/imagery overlays — the offline tile-pyramid format
//  ATAK uses. An .mbtiles file is a SQLite DB of raster tiles; Mapbox can't
//  read it directly, so we serve tiles from a tiny in-process HTTP server and
//  point a RasterSource + RasterLayer at http://127.0.0.1:port/<id>/{z}/{x}/{y}.
//  MBTiles store tiles in TMS row order; the server flips Y to XYZ.
//

import Foundation
import Network
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - SQLite reader

/// A read-only raster tile pyramid served over the local HTTP tile server.
/// Implemented by both MBTiles and GeoPackage (GPKG) readers.
protocol RasterTileDB: AnyObject {
    var minZoom: Int { get }
    var maxZoom: Int { get }
    var bounds: (n: Double, s: Double, e: Double, w: Double)? { get }
    var format: String { get } // tile image format: "png" / "jpg"
    func tile(z: Int, x: Int, y: Int) -> Data?
}

final class MBTilesDB: RasterTileDB {
    private var db: OpaquePointer?
    // The HTTP tile server handles requests on a concurrent queue and Mapbox
    // fetches many tiles at once — serialize access to this one SQLite handle.
    private let lock = NSLock()
    let minZoom: Int
    let maxZoom: Int
    /// north, south, east, west (WGS84) if the file declares bounds.
    let bounds: (n: Double, s: Double, e: Double, w: Double)?
    let format: String

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        var meta: [String: String] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name, value FROM metadata", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) {
                    meta[String(cString: k)] = String(cString: v)
                }
            }
        }
        sqlite3_finalize(stmt)
        format = meta["format"] ?? "png"
        minZoom = Int(meta["minzoom"] ?? "") ?? 0
        maxZoom = Int(meta["maxzoom"] ?? "") ?? 19
        if let parts = meta["bounds"]?.split(separator: ",").compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
           parts.count == 4 {
            // MBTiles bounds = west,south,east,north
            bounds = (n: parts[3], s: parts[1], e: parts[2], w: parts[0])
        } else {
            bounds = nil
        }
    }

    func tile(z: Int, x: Int, y: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return nil }
        let tmsY = (1 << z) - 1 - y // XYZ → TMS row
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(z))
        sqlite3_bind_int(stmt, 2, Int32(x))
        sqlite3_bind_int(stmt, 3, Int32(tmsY))
        guard sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    deinit { if db != nil { sqlite3_close(db) } }
}

// MARK: - GeoPackage (GPKG) raster reader

/// Reads raster tiles from a GeoPackage. Supports the common standard case:
/// a `tiles` data table whose grid matches the slippy-map (XYZ) scheme in
/// EPSG:3857 or 4326. GPKG tile_row is top-origin (= XYZ y, no TMS flip).
final class GPKGDb: RasterTileDB {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let tableName: String
    let minZoom: Int
    let maxZoom: Int
    let bounds: (n: Double, s: Double, e: Double, w: Double)?
    let format: String = "png"

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        // Find the first tiles table + its bounds/SRS from gpkg_contents.
        var table: String?
        var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0, srs = 4326
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT table_name, min_x, min_y, max_x, max_y, srs_id FROM gpkg_contents WHERE data_type='tiles' LIMIT 1", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW, let t = sqlite3_column_text(stmt, 0) {
            table = String(cString: t)
            minX = sqlite3_column_double(stmt, 1); minY = sqlite3_column_double(stmt, 2)
            maxX = sqlite3_column_double(stmt, 3); maxY = sqlite3_column_double(stmt, 4)
            srs = Int(sqlite3_column_int(stmt, 5))
        }
        sqlite3_finalize(stmt)
        guard let tbl = table else { sqlite3_close(db); return nil }
        tableName = tbl

        // Zoom range from the tile matrix (fall back to the tile table).
        var lo = 0, hi = 19
        var zstmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT min(zoom_level), max(zoom_level) FROM gpkg_tile_matrix WHERE table_name=?", -1, &zstmt, nil) == SQLITE_OK {
            sqlite3_bind_text(zstmt, 1, tbl, -1, SQLITE_TRANSIENT)
            if sqlite3_step(zstmt) == SQLITE_ROW, sqlite3_column_type(zstmt, 0) != SQLITE_NULL {
                lo = Int(sqlite3_column_int(zstmt, 0)); hi = Int(sqlite3_column_int(zstmt, 1))
            }
        }
        sqlite3_finalize(zstmt)
        minZoom = lo; maxZoom = hi

        func toLonLat(_ x: Double, _ y: Double) -> (Double, Double) {
            if srs == 3857 || srs == 900913 {
                let lon = x / 6378137.0 * 180.0 / .pi
                let lat = (2.0 * atan(exp(y / 6378137.0)) - .pi / 2.0) * 180.0 / .pi
                return (lon, lat)
            }
            return (x, y)
        }
        let (w, s) = toLonLat(minX, minY)
        let (e, n) = toLonLat(maxX, maxY)
        bounds = (abs(n) <= 90 && abs(s) <= 90 && abs(e) <= 180 && abs(w) <= 180 && n > s) ? (n, s, e, w) : nil
    }

    func tile(z: Int, x: Int, y: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        // GPKG tile_row is top-origin → same as XYZ y (no flip).
        guard sqlite3_prepare_v2(db, "SELECT tile_data FROM \"\(tableName)\" WHERE zoom_level=? AND tile_column=? AND tile_row=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(z)); sqlite3_bind_int(stmt, 2, Int32(x)); sqlite3_bind_int(stmt, 3, Int32(y))
        guard sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    deinit { if db != nil { sqlite3_close(db) } }
}

// MARK: - Local tile HTTP server

final class MBTilesTileServer {
    static let shared = MBTilesTileServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var dbs: [String: RasterTileDB] = [:]
    private let queue = DispatchQueue(label: "mbtiles.server", attributes: .concurrent)

    func register(_ db: RasterTileDB, id: String) {
        lock.lock(); dbs[id] = db; lock.unlock()
        start()
    }
    func unregister(_ id: String) { lock.lock(); dbs[id] = nil; lock.unlock() }

    /// Tile URL template for a registered MBTiles id (server is started lazily).
    func tileURLTemplate(for id: String) -> String? {
        guard port != 0 else { return nil }
        return "http://127.0.0.1:\(port)/\(id)/{z}/{x}/{y}"
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp)
            l.stateUpdateHandler = { [weak self, weak l] state in
                if case .ready = state, let p = l?.port?.rawValue { self?.port = p }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            listener = nil
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self, let data = data,
                  let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else { conn.cancel(); return }
            // "GET /<id>/<z>/<x>/<y>[.ext] HTTP/1.1"
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let comps = path.split(separator: "/").map(String.init)
            var body: Data?
            var ctype = "image/png"
            if comps.count >= 4,
               let z = Int(comps[1]), let x = Int(comps[2]),
               let y = Int(comps[3].split(separator: ".").first.map(String.init) ?? comps[3]) {
                self.lock.lock(); let db = self.dbs[comps[0]]; self.lock.unlock()
                body = db?.tile(z: z, x: x, y: y)
                if db?.format == "jpg" || db?.format == "jpeg" { ctype = "image/jpeg" }
            }
            let response: Data
            if let body = body {
                var head = "HTTP/1.1 200 OK\r\nContent-Type: \(ctype)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!
                head.append(body)
                response = head
            } else {
                response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".data(using: .utf8)!
            }
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

// MARK: - Overlay record

struct MBTilesOverlay: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var fileName: String   // the .mbtiles file (relative to the store dir)
    var minZoom: Int
    var maxZoom: Int
    var north: Double
    var south: Double
    var east: Double
    var west: Double
    var hasBounds: Bool
    var opacity: Double
    var visible: Bool
    var createdAt: Date
    /// Container format used to reopen the right reader: "mbtiles" or "gpkg".
    var container: String

    init(id: String, name: String, fileName: String, minZoom: Int, maxZoom: Int,
         north: Double, south: Double, east: Double, west: Double, hasBounds: Bool,
         opacity: Double = 1.0, visible: Bool = true, createdAt: Date = Date(),
         container: String = "mbtiles") {
        self.id = id; self.name = name; self.fileName = fileName
        self.minZoom = minZoom; self.maxZoom = maxZoom
        self.north = north; self.south = south; self.east = east; self.west = west
        self.hasBounds = hasBounds; self.opacity = opacity; self.visible = visible
        self.createdAt = createdAt; self.container = container
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decode(String.self, forKey: .fileName)
        minZoom = try c.decodeIfPresent(Int.self, forKey: .minZoom) ?? 0
        maxZoom = try c.decodeIfPresent(Int.self, forKey: .maxZoom) ?? 19
        north = try c.decodeIfPresent(Double.self, forKey: .north) ?? 0
        south = try c.decodeIfPresent(Double.self, forKey: .south) ?? 0
        east = try c.decodeIfPresent(Double.self, forKey: .east) ?? 0
        west = try c.decodeIfPresent(Double.self, forKey: .west) ?? 0
        hasBounds = try c.decodeIfPresent(Bool.self, forKey: .hasBounds) ?? false
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        container = try c.decodeIfPresent(String.self, forKey: .container) ?? "mbtiles"
    }
}

// MARK: - Store

@MainActor
final class MBTilesOverlayStore: ObservableObject {
    static let shared = MBTilesOverlayStore()

    @Published private(set) var overlays: [MBTilesOverlay] = []
    @Published var isImporting = false
    @Published var importStatus = ""
    @Published var lastError: String?

    private let dir: URL
    private let metaURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("MBTiles", isDirectory: true)
        metaURL = dir.appendingPathComponent("mbtiles.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        for o in overlays { registerServer(o) } // re-register on launch
    }

    func fileURL(_ overlay: MBTilesOverlay) -> URL { dir.appendingPathComponent(overlay.fileName) }
    func tileURLTemplate(_ overlay: MBTilesOverlay) -> String? { MBTilesTileServer.shared.tileURLTemplate(for: overlay.id) }

    private func openDB(_ overlay: MBTilesOverlay) -> RasterTileDB? {
        let path = fileURL(overlay).path
        return overlay.container == "gpkg" ? GPKGDb(path: path) : MBTilesDB(path: path)
    }

    private func registerServer(_ overlay: MBTilesOverlay) {
        if let db = openDB(overlay) { MBTilesTileServer.shared.register(db, id: overlay.id) }
    }

    @discardableResult
    func importMBTiles(from url: URL) async -> Bool { await importTileSet(from: url, container: "mbtiles") }

    @discardableResult
    func importGPKG(from url: URL) async -> Bool { await importTileSet(from: url, container: "gpkg") }

    @discardableResult
    private func importTileSet(from url: URL, container: String) async -> Bool {
        let label = container == "gpkg" ? "GeoPackage" : "MBTiles"
        isImporting = true; lastError = nil; importStatus = "Reading \(label)…"
        let id = UUID().uuidString
        let dest = dir.appendingPathComponent("\(id).\(container)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            let db: RasterTileDB? = container == "gpkg" ? GPKGDb(path: dest.path) : MBTilesDB(path: dest.path)
            guard let db = db else { throw NSError(domain: container, code: 1) }
            MBTilesTileServer.shared.register(db, id: id)
            let b = db.bounds
            overlays.append(MBTilesOverlay(
                id: id, name: url.deletingPathExtension().lastPathComponent, fileName: dest.lastPathComponent,
                minZoom: db.minZoom, maxZoom: db.maxZoom,
                north: b?.n ?? 85, south: b?.s ?? -85, east: b?.e ?? 180, west: b?.w ?? -180,
                hasBounds: b != nil, container: container
            ))
            persist()
            importStatus = "Imported \(label) (z\(db.minZoom)–\(db.maxZoom))"
            isImporting = false
            return true
        } catch {
            try? FileManager.default.removeItem(at: dest)
            lastError = "\(label) import failed: \(error.localizedDescription)"
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
        MBTilesTileServer.shared.unregister(id)
        try? FileManager.default.removeItem(at: fileURL(overlays[idx]))
        overlays.remove(at: idx); persist()
    }

    func removeAll() {
        for o in overlays {
            MBTilesTileServer.shared.unregister(o.id)
            try? FileManager.default.removeItem(at: fileURL(o))
        }
        overlays.removeAll(); persist()
    }

    private func mutate(_ id: String, _ change: (inout MBTilesOverlay) -> Void) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        change(&overlays[idx]); persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overlays) else { return }
        try? data.write(to: metaURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode([MBTilesOverlay].self, from: data) else { return }
        overlays = decoded.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path) }
    }
}
