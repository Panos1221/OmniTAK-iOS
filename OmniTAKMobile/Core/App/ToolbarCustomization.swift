//
//  ToolbarCustomization.swift
//  OmniTAKMobile
//
//  User-customizable bottom toolbar. The bar used to be six hardcoded
//  buttons; operators asked for the ATAK/TROP-style "build your own bar"
//  so they can put the shortcuts they actually use up front. This file
//  owns the catalog of available shortcuts, the persisted ordered config,
//  and the routing notifications. Every catalog entry maps to a REAL,
//  already-working feature — destinations switch the TabView, map-overlay
//  commands post the same notifications the radial menu / Full Tools grid
//  use, and tool shortcuts open the same sheets the 5x4 grid opens.
//

import SwiftUI

// MARK: - Root destinations

/// The TabView destinations. Promoted to a top-level type (was nested in
/// RootTabView) so the toolbar catalog can reference it without a cross-type
/// dependency.
enum RootTab: String, Hashable {
    case map, chat, servers, mesh, settings
}

// MARK: - Bar command kinds

/// What a non-destination shortcut does. Each case is wired to an existing
/// working feature in RootTabView.dispatch / the map's notification
/// observers — there are no placeholder actions here.
enum BarCommand: Equatable {
    case tools          // open the Tools popup (ToolsLauncherOverlay)
    case fullTools      // open the full 5x4 ATAK tools grid
    case lasso          // freehand multi-select on the map
    case measure        // distance / area measurement overlay
    case drawing        // open the drawing-tools panel
    case layers         // open the layers panel
    case drawingsList   // open the saved-drawings list
    case dropPin        // drop a marker at the current map center
    case engineToggle   // flip between 3D Globe and 2D Map
    case openTool(String) // open a specific ATAKTool sheet by its id
}

// MARK: - Bar item

/// One selectable entry for the customizable bottom bar. `id` is the stable
/// key persisted in the user's config; `BarItem.catalog` is the source of
/// truth that reconstructs the full item from a stored id.
struct BarItem: Identifiable, Equatable {
    let id: String
    let label: String
    let icon: String      // SF Symbol name
    let tint: Color
    let kind: Kind

    enum Kind: Equatable {
        case tab(RootTab)
        case command(BarCommand)
    }

    static func == (lhs: BarItem, rhs: BarItem) -> Bool { lhs.id == rhs.id }
}

// MARK: - Brand tints (mirror the Android LiquidGlassNavBar palette)

enum BarTint {
    static let map      = Color(red: 0x4F/255.0, green: 0xA8/255.0, blue: 0xFF/255.0)
    static let chat     = Color(red: 0x34/255.0, green: 0xC7/255.0, blue: 0x59/255.0)
    static let servers  = Color(red: 0x5A/255.0, green: 0xC8/255.0, blue: 0xFA/255.0)
    static let mesh     = Color(red: 0xFF/255.0, green: 0x9F/255.0, blue: 0x0A/255.0)
    static let tools    = Color(red: 0xFF/255.0, green: 0xCC/255.0, blue: 0x00/255.0)
    static let settings = Color(red: 0x8E/255.0, green: 0x8E/255.0, blue: 0x93/255.0)
    static let red      = Color(red: 0xFF/255.0, green: 0x3B/255.0, blue: 0x30/255.0)
    static let purple   = Color(red: 0xAF/255.0, green: 0x52/255.0, blue: 0xDE/255.0)
    static let teal     = Color(red: 0x30/255.0, green: 0xB0/255.0, blue: 0xC7/255.0)
    static let orange   = Color(red: 0xFF/255.0, green: 0x95/255.0, blue: 0x00/255.0)
}

// MARK: - Catalog

extension BarItem {
    /// Every shortcut a user can place in the bar. Order here is the order
    /// shown in the "add" palette (grouped by section below).
    static let catalog: [BarItem] = destinations + mapCommands + toolShortcuts

    /// TabView destinations — these switch the visible screen.
    static let destinations: [BarItem] = [
        BarItem(id: "tab.map",      label: "Map",      icon: "map",                               tint: BarTint.map,      kind: .tab(.map)),
        BarItem(id: "tab.chat",     label: "Chat",     icon: "bubble.left.and.bubble.right",      tint: BarTint.chat,     kind: .tab(.chat)),
        BarItem(id: "tab.servers",  label: "Servers",  icon: "server.rack",                       tint: BarTint.servers,  kind: .tab(.servers)),
        BarItem(id: "tab.mesh",     label: "Mesh",     icon: "antenna.radiowaves.left.and.right", tint: BarTint.mesh,     kind: .tab(.mesh)),
        BarItem(id: "tab.settings", label: "Settings", icon: "gearshape",                         tint: BarTint.settings, kind: .tab(.settings)),
    ]

    /// Map-overlay commands — post the same notifications the radial menu /
    /// Full Tools grid already use, so they drive real map behavior.
    static let mapCommands: [BarItem] = [
        BarItem(id: "cmd.tools",        label: "Tools",    icon: "wrench.and.screwdriver",         tint: BarTint.tools,  kind: .command(.tools)),
        BarItem(id: "cmd.fulltools",    label: "All Tools",icon: "square.grid.3x3.fill",           tint: BarTint.settings, kind: .command(.fullTools)),
        BarItem(id: "cmd.droppin",      label: "Drop Pin", icon: "mappin.and.ellipse",             tint: BarTint.red,    kind: .command(.dropPin)),
        BarItem(id: "cmd.measure",      label: "Measure",  icon: "ruler",                          tint: BarTint.teal,   kind: .command(.measure)),
        BarItem(id: "cmd.drawing",      label: "Drawing",  icon: "pencil.tip.crop.circle",         tint: BarTint.purple, kind: .command(.drawing)),
        BarItem(id: "cmd.layers",       label: "Layers",   icon: "square.3.layers.3d",             tint: BarTint.map,    kind: .command(.layers)),
        BarItem(id: "cmd.drawingslist", label: "Drawings", icon: "list.bullet.rectangle",          tint: BarTint.settings, kind: .command(.drawingsList)),
        BarItem(id: "cmd.lasso",        label: "Select",   icon: "lasso",                          tint: BarTint.orange, kind: .command(.lasso)),
        BarItem(id: "cmd.engine",       label: "2D / 3D",  icon: "globe.americas.fill",            tint: BarTint.map,    kind: .command(.engineToggle)),
    ]

    /// Tool shortcuts — open the exact same sheets the 5x4 grid opens, via
    /// the `.openToolSheet` notification handled by `ToolSheetHost`. Each id
    /// here MUST be present in ToolSheetHost.sheetView(for:) so it resolves
    /// to a real screen.
    static let toolShortcuts: [BarItem] = [
        BarItem(id: "tool.pointer",    label: "Point Drop", icon: "mappin.circle.fill",                  tint: BarTint.red,    kind: .command(.openTool("pointer"))),
        BarItem(id: "tool.routes",     label: "Routes",     icon: "point.topleft.down.to.point.bottomright.curvepath.fill", tint: BarTint.chat, kind: .command(.openTool("routes"))),
        BarItem(id: "tool.navigation", label: "Navigation", icon: "location.north.line.fill",            tint: BarTint.chat,   kind: .command(.openTool("turnbyturn"))),
        BarItem(id: "tool.teams",      label: "Teams",      icon: "person.3.fill",                       tint: BarTint.servers, kind: .command(.openTool("teams"))),
        BarItem(id: "tool.contacts",   label: "Contacts",   icon: "person.2.fill",                       tint: BarTint.servers, kind: .command(.openTool("contacts"))),
        BarItem(id: "tool.casevac",    label: "CASEVAC",    icon: "cross.case.fill",                     tint: BarTint.red,    kind: .command(.openTool("casevac"))),
        BarItem(id: "tool.nineline",   label: "9-Line",     icon: "airplane",                            tint: BarTint.red,    kind: .command(.openTool("nineline"))),
        BarItem(id: "tool.spotrep",    label: "SPOTREP",    icon: "doc.text.fill",                       tint: BarTint.mesh,   kind: .command(.openTool("spotrep"))),
        BarItem(id: "tool.alert",      label: "Emergency",  icon: "sos",                                 tint: BarTint.red,    kind: .command(.openTool("alert"))),
        BarItem(id: "tool.tracks",     label: "Tracks",     icon: "record.circle",                       tint: BarTint.purple, kind: .command(.openTool("tracks"))),
        BarItem(id: "tool.geofence",   label: "Geofence",   icon: "square.dashed",                       tint: BarTint.orange, kind: .command(.openTool("geofence"))),
        BarItem(id: "tool.adsb",       label: "ADS-B",      icon: "airplane.circle.fill",                tint: BarTint.mesh,   kind: .command(.openTool("adsb"))),
        BarItem(id: "tool.selfsa",     label: "Self SA",    icon: "dot.radiowaves.up.forward",           tint: BarTint.map,    kind: .command(.openTool("selfsa"))),
        BarItem(id: "tool.elevation",  label: "Elevation",  icon: "mountain.2.fill",                     tint: BarTint.teal,   kind: .command(.openTool("elevation"))),
        BarItem(id: "tool.los",        label: "Line of Sight", icon: "eye.fill",                         tint: BarTint.teal,   kind: .command(.openTool("los"))),
        BarItem(id: "tool.missionsync",label: "Mission Sync", icon: "arrow.triangle.2.circlepath",       tint: BarTint.chat,   kind: .command(.openTool("missionsync"))),
        BarItem(id: "tool.plugins",    label: "Plugins",    icon: "puzzlepiece.extension.fill",          tint: BarTint.settings, kind: .command(.openTool("plugins"))),
    ]

    static func item(for id: String) -> BarItem? { catalog.first { $0.id == id } }
}

// MARK: - Config store

/// Persists the operator's chosen bar layout (ordered list of item ids) and
/// drives the edit-mode flag. AppStorage-backed JSON so the layout survives
/// relaunches.
final class ToolbarConfigStore: ObservableObject {
    static let shared = ToolbarConfigStore()

    /// Visual cap for the floating pill — more than this and glyphs get too
    /// cramped to tap reliably. The rest live in the Tools popup / palette.
    static let maxItems = 6
    /// Never let the bar drop below this; there must always be a way to move
    /// around the app.
    static let minItems = 2

    private let key = "customToolbarItemIDs.v1"

    @Published private(set) var itemIDs: [String]
    /// True while the bar is in jiggle/drag edit mode.
    @Published var isEditing = false

    /// The default layout matches the original hardcoded bar so existing
    /// users see no change until they customize.
    static let defaultIDs = ["tab.map", "tab.chat", "tab.servers", "tab.mesh", "cmd.tools", "tab.settings"]

    private init() {
        if let raw = UserDefaults.standard.string(forKey: key),
           let data = raw.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data),
           !ids.isEmpty {
            // Drop any ids that no longer exist in the catalog (e.g. a tool
            // removed in an update) so we never render a dead button.
            itemIDs = ids.filter { BarItem.item(for: $0) != nil }
            if itemIDs.isEmpty { itemIDs = ToolbarConfigStore.defaultIDs }
        } else {
            itemIDs = ToolbarConfigStore.defaultIDs
        }
    }

    /// Resolved, render-ready items in the user's chosen order.
    var items: [BarItem] { itemIDs.compactMap { BarItem.item(for: $0) } }

    /// Catalog entries not currently in the bar — the "add a shortcut"
    /// palette. Preserves catalog (grouped) ordering.
    var availableToAdd: [BarItem] {
        BarItem.catalog.filter { !itemIDs.contains($0.id) }
    }

    var isFull: Bool { itemIDs.count >= ToolbarConfigStore.maxItems }
    var canRemove: Bool { itemIDs.count > ToolbarConfigStore.minItems }

    /// True if at least one destination tab remains — guards against the
    /// operator removing every screen and getting stuck.
    private func hasDestination(_ ids: [String]) -> Bool {
        ids.contains { id in
            if case .tab = BarItem.item(for: id)?.kind { return true }
            return false
        }
    }

    func add(_ id: String) {
        guard !isFull, !itemIDs.contains(id), BarItem.item(for: id) != nil else { return }
        itemIDs.append(id)
        persist()
    }

    func remove(_ id: String) {
        guard canRemove else { return }
        var next = itemIDs
        next.removeAll { $0 == id }
        // Don't allow removing the last destination — keep a way back to a
        // screen.
        guard hasDestination(next) else { return }
        itemIDs = next
        persist()
    }

    func move(from source: Int, to destination: Int) {
        guard source != destination,
              itemIDs.indices.contains(source),
              destination >= 0, destination < itemIDs.count else { return }
        var next = itemIDs
        let moved = next.remove(at: source)
        next.insert(moved, at: destination)
        itemIDs = next
        persist()
    }

    func resetToDefault() {
        itemIDs = ToolbarConfigStore.defaultIDs
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(itemIDs),
           let raw = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(raw, forKey: key)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Open a specific ATAKTool sheet by id (userInfo["id"]). Handled by
    /// `ToolSheetHost`.
    static let openToolSheet = Notification.Name("openToolSheet")
    /// Drop a marker at the current map center. Observed by the map.
    static let barDropPin = Notification.Name("barDropPin")
    /// Ask the bar to enter edit mode (from Settings / Tools popup).
    static let enterToolbarEditMode = Notification.Name("enterToolbarEditMode")
}
