//
//  KMLOverlaysPanel.swift
//  OmniTAKMobile
//
//  "Map Overlays" manager — import KML/KMZ and toggle / recolor / remove
//  imported vector overlays. Backed by KMLVectorOverlayStore (single
//  GeoJSONSource per overlay), so even a 50,000-feature import lists,
//  toggles, and renders without the per-feature-annotation crash.
//

import SwiftUI
import UniformTypeIdentifiers

struct KMLOverlaysPanel: View {
    @ObservedObject private var store = KMLVectorOverlayStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false

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
                    Text("Imported overlays render as a single GPU vector layer — large files (tens of thousands of features) stay smooth. Overlays show on the 2D map engine.")
                }

                if store.overlays.isEmpty {
                    Section {
                        Text("No overlays yet. Import a KML or KMZ to draw it on the map.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                } else {
                    Section("Overlays") {
                        ForEach(store.overlays) { overlay in
                            row(overlay)
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
            // Jump the map to the freshly imported overlay so it's immediately
            // visible (large overlays are often far from the current view).
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
            VStack(alignment: .leading, spacing: 2) {
                Text(overlay.name).lineLimit(1)
                Text("\(overlay.featureCount) features")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                NotificationCenter.default.post(name: .kmlZoomToOverlay, object: nil, userInfo: ["id": overlay.id])
                dismiss()
            } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(.borderless)
            Toggle("", isOn: Binding(
                get: { overlay.visible },
                set: { store.setVisible(overlay.id, $0) }
            ))
            .labelsHidden()
        }
        .swipeActions {
            Button(role: .destructive) { store.remove(overlay.id) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

extension Notification.Name {
    /// Posted by KMLOverlaysPanel to ask the map to frame an overlay's
    /// bounds (and switch to the 2D engine, where overlays render).
    static let kmlZoomToOverlay = Notification.Name("kmlZoomToOverlay")
}
