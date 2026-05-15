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

            ChatView(chatManager: ChatManager.shared)
                .tag(Tab.chat)

            ServersView()
                .tag(Tab.servers)

            MeshtasticConnectionView()
                .tag(Tab.mesh)

            SettingsView()
                .tag(Tab.settings)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
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

/// Bottom bar with 6 items: 5 navigation destinations + a Tools
/// command. The Tools button is visually identical to the others
/// (icon + label + active highlight) but tapping it doesn't switch
/// `selectedTab` — it triggers a callback (which opens the
/// launcher popup in RootTabView). All six fit without a "More"
/// overflow because we're laying this out by hand.
private struct CustomTabBar: View {
    @Binding var selectedTab: RootTabView.Tab
    let onToolsTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            tabItem(tab: .map, icon: "map", label: "Map")
            tabItem(tab: .chat, icon: "bubble.left.and.bubble.right", label: "Chat")
            tabItem(tab: .servers, icon: "server.rack", label: "Servers")
            tabItem(tab: .mesh, icon: "antenna.radiowaves.left.and.right", label: "Mesh")
            toolsItem
            tabItem(tab: .settings, icon: "gearshape", label: "Settings")
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(.bar) // matches system tab bar material
        .overlay(alignment: .top) {
            // Hairline divider to match the system tab bar's top
            // edge — without it the bar floats and looks unanchored.
            Divider()
        }
    }

    private func tabItem(tab: RootTabView.Tab, icon: String, label: String) -> some View {
        let active = selectedTab == tab
        return Button {
            // Haptic feedback to match the system tab bar's behavior.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: active ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(active ? .accentColor : .secondary)
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
            VStack(spacing: 3) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 22))
                Text("Tools")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tools")
        .accessibilityHint("Opens a popup with Lasso Select and other tools")
    }
}
