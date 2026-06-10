//
//  PluginHost.swift
//  OmniTAKMobile
//
//  The surface a plugin uses to register hooks into the host app. Passed to
//  `OmniTAKPlugin.activate(host:)`. There are exactly four hooks, mirrored
//  1:1 on Android so plugins port across platforms.
//

import SwiftUI
import CoreLocation

/// The four host hooks a plugin can register through during `activate(host:)`.
///
/// All registrations are tagged with the currently-activating plugin's
/// `pluginId` by the host, so `deactivate(pluginId:)` can cleanly remove just
/// that plugin's hooks.
protocol PluginHost: AnyObject {
    /// Register a SwiftUI overlay rendered in the engine-agnostic map chrome
    /// layer. The closure is invoked each render pass; return a type-erased
    /// view. The overlay sits ABOVE the map and BELOW the radial menu, on
    /// BOTH map engines (Cesium 3D + Mapbox 2D), because it mounts in the
    /// shared `mapChrome` seam — never inside a single engine.
    func registerMapOverlay(_ overlay: @escaping () -> AnyView)

    /// Register an entry in the map long-press radial menu (empty-map
    /// context). `onSelect` fires with the pressed map coordinate when the
    /// operator taps the entry. The entry is still subject to the per-plugin
    /// enable filter.
    func registerRadialAction(_ action: RadialMenuItem,
                              onSelect: @escaping (CLLocationCoordinate2D) -> Void)

    /// Register a handler called for every inbound CoT position event AFTER
    /// the core store ingests it. Return `true` to mark the event consumed
    /// (short-circuits remaining handlers). Handlers run on the main thread —
    /// keep them cheap and non-blocking.
    func registerCoTHandler(_ handler: @escaping (CoTEvent) -> Bool)

    /// Register a row in Settings → Plugins that navigates to the plugin's
    /// `settingsContent()`. `icon` is an SF Symbol name.
    func registerSettingsRow(label: String, icon: String)
}
