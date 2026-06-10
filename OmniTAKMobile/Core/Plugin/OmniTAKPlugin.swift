//
//  OmniTAKPlugin.swift
//  OmniTAKMobile
//
//  The OmniTAK plugin SDK — protocol every bundled plugin conforms to.
//
//  STORE-COMPLIANCE: plugins are COMPILE-TIME Swift types. There is no
//  dynamic / downloadable code, no dylib loading, no remote execution. A
//  plugin is just a class that conforms to this protocol and gets registered
//  at app start in `PluginRegistry.loadBundledPlugins()`. This keeps the SDK
//  App-Store compliant.
//
//  TRUST MODEL: a plugin runs IN-PROCESS with the host app's full
//  permissions. There is no sandbox. Authors (and reviewers) must treat a
//  plugin's code as part of the app. See docs/PLUGIN_AUTHORING.md.
//

import SwiftUI

/// A bundled OmniTAK plugin. Conform a final class to this protocol, then
/// register it in `PluginRegistry.loadBundledPlugins()`.
///
/// The shape is intentionally identical to the Android `OmniTAKPlugin`
/// interface so a plugin ports across platforms in roughly a day — the same
/// `pluginId` (reverse-DNS, e.g. "soy.engindearing.adsb") drives settings
/// persistence on both platforms.
protocol OmniTAKPlugin: AnyObject {
    /// Stable reverse-DNS identifier, e.g. "soy.engindearing.adsb". Used as
    /// the persistence key for the enable flag and to tag every registered
    /// hook with its owner. MUST be unique and stable across releases.
    var pluginId: String { get }

    /// Human-readable name shown in Settings → Plugins.
    var displayName: String { get }

    /// Semantic version of the plugin, e.g. "1.0.0".
    var pluginVersion: String { get }

    /// Plugin author / vendor.
    var pluginAuthor: String { get }

    /// One-line description shown under the plugin row.
    var pluginDescription: String { get }

    /// Called when the plugin is activated (at app start if enabled, or when
    /// the user toggles it on). Register the plugin's hooks on `host` here.
    func activate(host: PluginHost)

    /// Called when the plugin is deactivated (user toggles it off). Stop any
    /// work the plugin started; the registry removes the plugin's registered
    /// hooks from the host automatically.
    func deactivate()

    /// Optional settings UI. Returns a type-erased SwiftUI view shown when the
    /// user taps into the plugin row in Settings → Plugins. Default: `nil`.
    func settingsContent() -> AnyView?
}

extension OmniTAKPlugin {
    /// Default: no settings UI.
    func settingsContent() -> AnyView? { nil }
}
