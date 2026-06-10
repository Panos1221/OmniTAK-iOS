//
//  DiagnosticsPlugin.swift
//  OmniTAKMobile
//
//  A tiny internal plugin that exercises the OTHER two host hooks the ADS-B
//  reference plugin doesn't need: `registerRadialAction` and
//  `registerCoTHandler`. Together with ADS-B (overlay + settings row) this
//  wires the ENTIRE host surface so the whole SDK is exercised end-to-end.
//
//  It is DISABLED by default (see PluginSettingsManager.registeredDisabledByDefault)
//  so it never affects shipping users — it only proves the surface works, and
//  is covered by PluginSDKTests regardless of its enable state.
//

import SwiftUI
import CoreLocation

final class DiagnosticsPlugin: OmniTAKPlugin {
    let pluginId = "soy.engindearing.diagnostics"
    let displayName = "Diagnostics"
    let pluginVersion = "1.0.0"
    let pluginAuthor = "Engindearing"
    let pluginDescription = "Internal SDK diagnostics — radial probe + CoT event counter (off by default)"

    /// Count of inbound CoT events seen by the registered handler. Useful as a
    /// liveness probe when the plugin is enabled during development.
    private(set) var cotEventCount = 0

    func activate(host: PluginHost) {
        // Hook 3: radial action. Adds a "Diag" entry to the empty-map
        // long-press menu; tapping it logs the pressed coordinate.
        host.registerRadialAction(
            RadialMenuItem(
                icon: "ladybug",
                label: "Diag",
                action: .custom("plugin_diag")
            ),
            onSelect: { coordinate in
                print("[DiagnosticsPlugin] radial action at \(coordinate.latitude), \(coordinate.longitude)")
            }
        )

        // Hook 4: CoT handler. Counts inbound position events and returns
        // false (does NOT consume) so the rest of the pipeline is untouched.
        host.registerCoTHandler { [weak self] _ in
            self?.cotEventCount += 1
            return false
        }
    }

    func deactivate() {
        cotEventCount = 0
    }
}
