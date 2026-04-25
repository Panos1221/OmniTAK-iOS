//
//  RootTabView.swift
//  OmniTAKMobile
//
//  Top-level TabView matching the Android client's bottom navigation.
//  Five primary destinations: Map / Chat / Servers / Mesh / Settings.
//

import SwiftUI

struct RootTabView: View {
    @SceneStorage("selectedRootTab") private var selectedTab: Tab = .map

    enum Tab: String {
        case map, chat, servers, mesh, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ATAKMapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)

            ChatView(chatManager: ChatManager.shared)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)

            ServersView()
                .tabItem { Label("Servers", systemImage: "server.rack") }
                .tag(Tab.servers)

            MeshtasticConnectionView()
                .tabItem { Label("Mesh", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.mesh)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}
