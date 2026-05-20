//
//  ToolsLauncherSheet.swift
//  OmniTAKMobile
//
//  Bottom-sheet popup launched from the Tools shortcut. The map stays
//  visible/interactive behind it. Holds the marquee Lasso Select, the map
//  engine toggle, a set of quick tools (which open the same real screens as
//  the Full Tools grid via .openToolSheet), a "Customize toolbar" entry,
//  and a passthrough to the full 5x4 grid.
//

import SwiftUI

struct ToolsLauncherSheet: View {
    let onLasso: () -> Void
    let onFullTools: () -> Void
    let onCustomize: () -> Void
    let onDismiss: () -> Void

    @AppStorage("mapEngine") private var mapEngineRaw: String = MapEngine.cesium3D.rawValue
    private var mapEngine: MapEngine { MapEngine(rawValue: mapEngineRaw) ?? .cesium3D }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Marquee row — Lasso Select.
                row(icon: "lasso", iconColor: .orange, title: "Lasso Select",
                    subtitle: "Long-press + drag on the map to multi-select",
                    bold: true, action: onLasso)

                Divider().padding(.leading, 70)

                // Map engine toggle.
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

                // Quick tools — open the same real screens the Full Tools grid
                // opens, routed through ToolSheetHost so they work from here.
                quickTool(icon: "mappin.circle.fill", color: BarTint.red, title: "Point Drop",
                          subtitle: "Place and label a tactical marker", toolID: "pointer")
                Divider().padding(.leading, 70)
                quickTool(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", color: BarTint.chat,
                          title: "Routes", subtitle: "Plan and navigate routes", toolID: "routes")
                Divider().padding(.leading, 70)
                quickTool(icon: "cross.case.fill", color: BarTint.red, title: "CASEVAC",
                          subtitle: "Casualty evacuation request", toolID: "casevac")
                Divider().padding(.leading, 70)
                quickTool(icon: "airplane.circle.fill", color: BarTint.mesh, title: "ADS-B",
                          subtitle: "Live aircraft tracking", toolID: "adsb")

                Divider().padding(.leading, 70)

                quickTool(icon: "square.3.layers.3d", color: BarTint.purple, title: "Map Overlays",
                          subtitle: "Import & toggle KML/KMZ overlays (handles huge files)", toolID: "kml")

                Divider().padding(.leading, 70)

                // Build-your-own-bar entry.
                row(icon: "slider.horizontal.3", iconColor: BarTint.tools, title: "Customize Toolbar",
                    subtitle: "Pick and arrange your own bottom-bar shortcuts",
                    bold: false, action: onCustomize)

                Divider().padding(.leading, 70)

                // Passthrough to the full 5x4 grid.
                row(icon: "square.grid.3x3.fill", iconColor: .secondary, title: "Full Tools…",
                    subtitle: "Drawing, Measure, CASEVAC, Routes, and more",
                    bold: false, action: onFullTools)
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: 420)
    }

    private func quickTool(icon: String, color: Color, title: String, subtitle: String, toolID: String) -> some View {
        row(icon: icon, iconColor: color, title: title, subtitle: subtitle, bold: false) {
            onDismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                NotificationCenter.default.post(name: .openToolSheet, object: nil, userInfo: ["id": toolID])
            }
        }
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

// MARK: - Tap-outside-to-dismiss overlay wrapper

/// Wraps `ToolsLauncherSheet` in a tap-dismissible scrim. iOS's native
/// `.sheet` doesn't dismiss on outside taps, so the dim area behind the
/// panel is a tap target; swipe-down on the panel also dismisses.
struct ToolsLauncherOverlay: View {
    let onLasso: () -> Void
    let onFullTools: () -> Void
    let onCustomize: () -> Void
    let onDismiss: () -> Void

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ToolsLauncherSheet(
                    onLasso: onLasso,
                    onFullTools: onFullTools,
                    onCustomize: onCustomize,
                    onDismiss: onDismiss
                )
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
            .padding(.bottom, 78)
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
