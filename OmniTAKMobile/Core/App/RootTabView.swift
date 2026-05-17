//
//  RootTabView.swift
//  OmniTAKMobile
//
//  Top-level navigation. The system TabView caps visible tabs at 5
//  before forcing a "More" overflow tab, so we hide its built-in
//  bar (UITabBar.appearance().isHidden = true) and overlay our own
//  HStack along the bottom edge with all six buttons. The underlying
//  TabView still manages tab lifecycle / state preservation —
//  switching tabs doesn't tear down the previous view, so things
//  like the map's region, chat scroll position, and server picker
//  state persist exactly like they did before.
//
//  Tools is a "command" tab — tapping it pops a short bottom-sheet
//  popup (ToolsLauncherSheet) instead of switching destination.
//  Lasso Select is the marquee entry in that sheet; "Full Tools…"
//  routes to the existing 5x4 ATAKToolsView grid via the .showFullTools
//  notification.
//

import SwiftUI

struct RootTabView: View {
    @SceneStorage("selectedRootTab") private var selectedTab: Tab = .map
    @State private var showToolsLauncher = false

    enum Tab: String, Hashable {
        case map, chat, servers, mesh, settings
    }

    init() {
        // The custom bar at the bottom is the only bar we want; the
        // system one would either auto-collapse our 6th tab into a
        // "More" overflow, or stack behind our overlay.
        UITabBar.appearance().isHidden = true
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ATAKMapView()
                .tag(Tab.map)
                .ignoresSafeArea(edges: .bottom)

            ChatView(chatManager: ChatManager.shared)
                .tag(Tab.chat)

            ServersView()
                .tag(Tab.servers)

            MeshtasticConnectionView()
                .tag(Tab.mesh)

            SettingsView()
                .tag(Tab.settings)
        }
        // Overlay (not safeAreaInset) so the map renders edge-to-edge
        // under the floating LiquidGlass pill — matches Android parity.
        // Non-map tabs handle their own bottom padding via their own
        // ScrollView contentInset.
        .overlay(alignment: .bottom) {
            CustomTabBar(
                selectedTab: $selectedTab,
                onToolsTap: { showToolsLauncher = true }
            )
        }
        .sheet(isPresented: $showToolsLauncher) {
            // iOS 16+ gets the short-detent treatment (map / current
            // tab stays visible under the popup). iOS 15 falls back
            // to a standard sheet — still functional, just bigger.
            Group {
                if #available(iOS 16.4, *) {
                    ToolsLauncherSheet(
                        onLasso: handleLasso,
                        onFullTools: handleFullTools
                    )
                    .presentationDetents([.height(220), .medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(220)))
                } else if #available(iOS 16.0, *) {
                    ToolsLauncherSheet(
                        onLasso: handleLasso,
                        onFullTools: handleFullTools
                    )
                    .presentationDetents([.height(220), .medium])
                    .presentationDragIndicator(.visible)
                } else {
                    ToolsLauncherSheet(
                        onLasso: handleLasso,
                        onFullTools: handleFullTools
                    )
                }
            }
        }
    }

    private func handleLasso() {
        showToolsLauncher = false
        // Lasso only makes sense on the map; route there before
        // posting so the gesture recognizer is alive when the
        // notification lands.
        selectedTab = .map
        NotificationCenter.default.post(name: .startLassoMode, object: nil)
    }

    private func handleFullTools() {
        showToolsLauncher = false
        selectedTab = .map
        // Tiny delay so the launcher's dismiss animation finishes
        // before the 5x4 tools sheet tries to present — SwiftUI
        // refuses two stacked sheets from the same anchor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .showFullTools, object: nil)
        }
    }
}

// MARK: - Custom Tab Bar

/// Floating "Liquid Glass" pill matching the Android LiquidGlassNavBar.
/// Rounded translucent capsule with horizontal margin, per-tab brand
/// colors, ultra-thin material backdrop, and a shadow so it reads as
/// hovering over the map rather than anchored to the bottom edge.
private struct CustomTabBar: View {
    @Binding var selectedTab: RootTabView.Tab
    let onToolsTap: () -> Void

    // Per-tab brand colors mirror Android NavTabs — each glyph carries
    // its own tint instead of all five being the same accent color.
    private static let mapTint      = Color(red: 0x4F/255.0, green: 0xA8/255.0, blue: 0xFF/255.0)
    private static let chatTint     = Color(red: 0x34/255.0, green: 0xC7/255.0, blue: 0x59/255.0)
    private static let serversTint  = Color(red: 0x5A/255.0, green: 0xC8/255.0, blue: 0xFA/255.0)
    private static let meshTint     = Color(red: 0xFF/255.0, green: 0x9F/255.0, blue: 0x0A/255.0)
    private static let toolsTint    = Color(red: 0xFF/255.0, green: 0xCC/255.0, blue: 0x00/255.0)
    private static let settingsTint = Color(red: 0x8E/255.0, green: 0x8E/255.0, blue: 0x93/255.0)

    var body: some View {
        HStack(spacing: 0) {
            tabItem(tab: .map,      icon: "map",                                  label: "Map",      tint: Self.mapTint)
            tabItem(tab: .chat,     icon: "bubble.left.and.bubble.right",         label: "Chat",     tint: Self.chatTint)
            tabItem(tab: .servers,  icon: "server.rack",                          label: "Servers",  tint: Self.serversTint)
            tabItem(tab: .mesh,     icon: "antenna.radiowaves.left.and.right",    label: "Mesh",     tint: Self.meshTint)
            toolsItem
            tabItem(tab: .settings, icon: "gearshape",                            label: "Settings", tint: Self.settingsTint)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            // Frosted backdrop + dark fill — translucent enough to see
            // the map through, opaque enough to keep glyphs readable.
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .background(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 14)
        .padding(.bottom, 4) // sits just above the system home-indicator
    }

    private func tabItem(tab: RootTabView.Tab, icon: String, label: String, tint: Color) -> some View {
        let active = selectedTab == tab
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill(active ? tint.opacity(0.22) : Color.clear)
                        .frame(width: active ? 40 : 32, height: active ? 40 : 32)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: active ? .semibold : .regular))
                        .foregroundColor(active ? tint : Color.white.opacity(0.85))
                }
                Text(label)
                    .font(.system(size: 10, weight: active ? .semibold : .medium))
                    .foregroundColor(active ? tint : Color.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var toolsItem: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onToolsTap()
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Circle().fill(Color.clear).frame(width: 32, height: 32)
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 20))
                        .foregroundColor(Self.toolsTint)
                }
                Text("Tools")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tools")
        .accessibilityHint("Opens a popup with Lasso Select and other tools")
    }
}
