//
//  ToolsLauncherSheet.swift
//  OmniTAKMobile
//
//  Issue #16 — small bottom-sheet popup launched from the map's
//  floating wrench button. Map stays visible behind it
//  (presentationDetents .height(220) + .medium). Two rows: the
//  marquee "Lasso Select" + a passthrough to the full 5x4 tools grid.
//
//  Design contract: map is the most important part of the app and
//  must remain visible while choosing a tool. This sheet sits at the
//  bottom edge, taking ~220pt by default, and supports
//  presentationBackgroundInteraction so the user can still pan/zoom
//  the underlying map without dismissing.
//

import SwiftUI

struct ToolsLauncherSheet: View {
    let onLasso: () -> Void
    let onFullTools: () -> Void

    // Map engine toggle lives here (not in the 5x4 grid) — mode switchers
    // belong in the always-visible quick-tools popup so operators don't
    // have to chase them through tiles. As we promote more working tools
    // out of Full Tools into the slick popup, follow this pattern.
    @AppStorage("mapEngine") private var mapEngineRaw: String = MapEngine.cesium3D.rawValue
    private var mapEngine: MapEngine { MapEngine(rawValue: mapEngineRaw) ?? .cesium3D }

    var body: some View {
        VStack(spacing: 0) {
            // Marquee row — Lasso Select is the K9Blue SAR primary
            // ask. Bigger tap target, orange tint to match the
            // in-progress lasso outline.
            row(
                icon: "lasso",
                iconColor: .orange,
                title: "Lasso Select",
                subtitle: "Long-press + drag on the map to multi-select",
                bold: true,
                action: onLasso
            )

            Divider().padding(.leading, 70)

            // Map engine toggle — flips between Cesium 3D and Mapbox 2D
            // for the whole app. Label reflects what tapping will DO.
            row(
                icon: mapEngine == .cesium3D ? "map.fill" : "globe.americas.fill",
                iconColor: mapEngine == .cesium3D ? Color(white: 0.55) : Color(red: 0.31, green: 0.66, blue: 1.0),
                title: mapEngine == .cesium3D ? "Switch to 2D Map" : "Switch to 3D Globe",
                subtitle: mapEngine == .cesium3D
                    ? "Currently 3D Cesium — drop to Mapbox 2D for offline / low-bandwidth"
                    : "Currently 2D Mapbox — back to the photoreal Cesium globe",
                bold: false,
                action: {
                    let next: MapEngine = mapEngine == .cesium3D ? .mapbox2D : .cesium3D
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    mapEngineRaw = next.rawValue
                }
            )

            Divider().padding(.leading, 70)

            // Passthrough to the full 5x4 grid. Useful when the
            // user wants Measure / Drawing / CASEVAC / etc. without
            // navigating up to whatever existing entry point ATAK
            // tools has.
            row(
                icon: "square.grid.3x3.fill",
                iconColor: .secondary,
                title: "Full Tools…",
                subtitle: "Drawing, Measure, CASEVAC, Routes, and more",
                bold: false,
                action: onFullTools
            )
            // Intentionally NO trailing Spacer — the panel sizes to its
            // rows so the popup is only as tall as it needs. The old
            // Spacer(minLength: 0) was a holdover from the .sheet detent
            // and made the panel eat the lower half of the screen.
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func row(icon: String, iconColor: Color, title: String, subtitle: String, bold: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: bold ? .semibold : .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: bold ? .semibold : .regular))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
struct ToolsLauncherSheet_Previews: PreviewProvider {
    static var previews: some View {
        ToolsLauncherSheet(onLasso: {}, onFullTools: {})
            .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Tap-outside-to-dismiss overlay wrapper

/// Custom overlay that wraps `ToolsLauncherSheet` in a tap-dismissible
/// scrim — iOS's native `.sheet` doesn't dismiss on outside taps (only
/// swipe-down), and the operator-feedback fix is to make the dim area
/// behind the panel a tap target. Also supports swipe-down on the panel
/// itself so it feels like a sheet, just with extra dismiss affordances.
struct ToolsLauncherOverlay: View {
    let onLasso: () -> Void
    let onFullTools: () -> Void
    let onDismiss: () -> Void

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tap-outside-to-dismiss backdrop. Faint dim so the map +
            // chrome stays readable behind the popup.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            // Panel — visually identical to the prior .sheet detent.
            VStack(spacing: 0) {
                // Grab handle, doubles as a swipe-down dismiss target.
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ToolsLauncherSheet(onLasso: onLasso, onFullTools: onFullTools)
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 78) // clear the floating LiquidGlass tab bar
            .offset(y: max(0, dragOffset))
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        if value.translation.height > 60 || value.predictedEndTranslation.height > 140 {
                            onDismiss()
                        }
                    }
            )
        }
    }
}
