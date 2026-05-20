//
//  KMLOverlaysPanel.swift
//  OmniTAKMobile
//
//  "Map Overlays" manager — full CRUD over imported KML/KMZ vector overlays.
//  Backed by KMLVectorOverlayStore (single GeoJSONSource per overlay), so even
//  a 50,000-feature import lists, edits, and renders without the per-feature
//  annotation crash.
//
//  Create: import KML/KMZ.   Read: list + per-overlay detail/metadata.
//  Update: rename, recolor, opacity, line width, visibility, zoom-to-fit.
//  Delete: per-overlay (with confirm) + delete-all.
//

import SwiftUI
import UniformTypeIdentifiers

struct KMLOverlaysPanel: View {
    @ObservedObject private var store = KMLVectorOverlayStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var showDeleteAll = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import KML / KMZ", systemImage: "square.and.arrow.down")
                    }
                    if store.isImporting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(store.importStatus.isEmpty ? "Importing…" : store.importStatus)
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    if let err = store.lastError {
                        Text(err).font(.footnote).foregroundColor(.red)
                    }
                } footer: {
                    Text("Imported overlays render as a single GPU vector layer — large files (tens of thousands of features) stay smooth. Tap an overlay to rename, recolor, or restyle it. Overlays show on the 2D map engine.")
                }

                if store.overlays.isEmpty {
                    Section {
                        Text("No overlays yet. Import a KML or KMZ to draw it on the map.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                } else {
                    Section("Overlays") {
                        ForEach(store.overlays) { overlay in
                            NavigationLink {
                                KMLOverlayDetailView(overlayID: overlay.id)
                            } label: {
                                row(overlay)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.remove(overlay.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button { store.setVisible(overlay.id, !overlay.visible) } label: {
                                    Label(overlay.visible ? "Hide" : "Show",
                                          systemImage: overlay.visible ? "eye.slash" : "eye")
                                }.tint(.indigo)
                            }
                        }
                    }

                    Section {
                        Button(role: .destructive) { showDeleteAll = true } label: {
                            Label("Delete All Overlays", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Map Overlays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { importPicked(url) }
            }
            .confirmationDialog("Delete all overlays?", isPresented: $showDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { store.removeAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every imported overlay. It can't be undone.")
            }
        }
    }

    private var allowedTypes: [UTType] {
        var types: [UTType] = []
        if let kml = UTType(filenameExtension: "kml") { types.append(kml) }
        if let kmz = UTType(filenameExtension: "kmz") { types.append(kmz) }
        return types.isEmpty ? [.data] : types
    }

    private func importPicked(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            store.lastError = "Couldn't read the selected file."
            return
        }
        Task {
            await store.importKML(from: tmp)
            try? FileManager.default.removeItem(at: tmp)
            if let last = store.overlays.last {
                NotificationCenter.default.post(name: .kmlZoomToOverlay, object: nil, userInfo: ["id": last.id])
            }
        }
    }

    @ViewBuilder
    private func row(_ overlay: KMLVectorOverlay) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: overlay.colorHex))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5))
                .opacity(overlay.visible ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 2) {
                Text(overlay.name).lineLimit(1)
                Text("\(overlay.featureCount) features")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: overlay.visible ? "eye" : "eye.slash")
                .foregroundColor(.secondary)
                .font(.footnote)
        }
    }
}

// MARK: - Per-overlay editor (full CRUD: rename / recolor / restyle / delete)

struct KMLOverlayDetailView: View {
    @ObservedObject private var store = KMLVectorOverlayStore.shared
    let overlayID: String
    @Environment(\.dismiss) private var dismiss
    @State private var nameField = ""
    @State private var showDelete = false

    private static let palette = [
        "#A78BFA", "#5AC8FA", "#34C759", "#FF9F0A", "#FF375F",
        "#FFD60A", "#0A84FF", "#FF453A", "#30D158", "#FFFFFF",
    ]

    private var overlay: KMLVectorOverlay? { store.overlays.first { $0.id == overlayID } }

    var body: some View {
        Form {
            if let o = overlay {
                Section("Name") {
                    TextField("Overlay name", text: $nameField)
                        .onSubmit { store.rename(o.id, to: nameField) }
                        .submitLabel(.done)
                }

                Section("Appearance") {
                    Toggle("Visible", isOn: Binding(get: { o.visible }, set: { store.setVisible(o.id, $0) }))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color").font(.subheadline)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                            ForEach(Self.palette, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: o.colorHex.uppercased() == hex ? 3 : 0))
                                    .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
                                    .onTapGesture { store.setColor(o.id, hex: hex) }
                            }
                        }
                        ColorPicker("Custom color", selection: Binding(
                            get: { Color(hex: o.colorHex) },
                            set: { store.setColor(o.id, hex: hexString(from: $0)) }
                        ))
                    }

                    VStack(alignment: .leading) {
                        Text("Opacity — \(Int(o.opacity * 100))%").font(.subheadline)
                        Slider(value: Binding(get: { o.opacity }, set: { store.setOpacity(o.id, $0) }), in: 0.05...1.0)
                    }

                    VStack(alignment: .leading) {
                        Text(String(format: "Line width — %.1f×", o.lineWidth)).font(.subheadline)
                        Slider(value: Binding(get: { o.lineWidth }, set: { store.setLineWidth(o.id, $0) }), in: 0.5...6.0)
                    }
                }

                Section("Info") {
                    infoRow("Features", "\(o.featureCount)")
                    infoRow("Imported", o.createdAt.formatted(date: .abbreviated, time: .shortened))
                    infoRow("Bounds", String(format: "%.3f, %.3f → %.3f, %.3f", o.minLat, o.minLon, o.maxLat, o.maxLon))
                    Button {
                        NotificationCenter.default.post(name: .kmlZoomToOverlay, object: nil, userInfo: ["id": o.id])
                        dismiss()
                    } label: {
                        Label("Zoom to overlay", systemImage: "scope")
                    }
                }

                Section {
                    Button(role: .destructive) { showDelete = true } label: {
                        Label("Delete overlay", systemImage: "trash")
                    }
                }
            } else {
                Text("Overlay removed.").foregroundColor(.secondary)
            }
        }
        .navigationTitle(overlay?.name ?? "Overlay")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nameField = overlay?.name ?? "" }
        .onDisappear { if let o = overlay, nameField != o.name { store.rename(o.id, to: nameField) } }
        .confirmationDialog("Delete this overlay?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.remove(overlayID); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private func hexString(from color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

extension Notification.Name {
    /// Posted by KMLOverlaysPanel to ask the map to frame an overlay's
    /// bounds (and switch to the 2D engine, where overlays render).
    static let kmlZoomToOverlay = Notification.Name("kmlZoomToOverlay")
}
