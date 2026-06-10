//
//  ToolSheetHost.swift
//  OmniTAKMobile
//
//  Presents a tool's sheet when a customizable-bar shortcut (or the Tools
//  popup) fires `.openToolSheet`. These are the exact same screens the 5x4
//  ATAKToolsView grid opens — routing through one host lets the bar reach
//  the full tool catalog without duplicating each tool's presentation in
//  multiple places.
//

import SwiftUI

private struct ToolSheetID: Identifiable, Equatable { let id: String }

struct ToolSheetHost: ViewModifier {
    @State private var active: ToolSheetID?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openToolSheet)) { note in
                if let id = note.userInfo?["id"] as? String {
                    active = ToolSheetID(id: id)
                }
            }
            .sheet(item: $active) { sheet in
                sheetView(for: sheet.id)
            }
    }

    @ViewBuilder
    private func sheetView(for id: String) -> some View {
        // ToolRegistry is the single tool catalog; this host is the single
        // dispatcher. Unknown ids resolve to an empty sheet (same behavior
        // the old hand-written switch had).
        if let descriptor = ToolRegistry.descriptor(for: id) {
            descriptor.destination({ active = nil })
        } else {
            EmptyView()
        }
    }
}

extension View {
    /// Attach once near the app root so `.openToolSheet` notifications
    /// resolve to real tool screens.
    func toolSheetHost() -> some View { modifier(ToolSheetHost()) }
}
