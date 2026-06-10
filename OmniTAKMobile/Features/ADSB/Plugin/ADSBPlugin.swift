//
//  ADSBPlugin.swift
//  OmniTAKMobile
//
//  REFERENCE PLUGIN. Wraps the existing ADS-B feature as an OmniTAKPlugin
//  with ZERO behavior change.
//
//  WHY THE RENDERING PATH IS UNTOUCHED: ADS-B does not draw through a SwiftUI
//  overlay. Aircraft flow as a `[Aircraft]` data array straight into BOTH map
//  engines (TacticalMapView + CesiumMainMap), gated by
//  `ADSBTrafficService.shared.settings.isEnabled`. That proven pipeline stays
//  byte-identical. The plugin only ADDS the SDK wrapper: a map-overlay hook
//  (a thin status surface) and a settings row that opens the existing
//  ADSBTrafficView verbatim. The single source of truth remains
//  `ADSBTrafficService.shared`.
//

import SwiftUI

final class ADSBPlugin: OmniTAKPlugin {
    let pluginId = "soy.engindearing.adsb"
    let displayName = "ADS-B"
    let pluginVersion = "1.0.0"
    let pluginAuthor = "Engindearing"
    let pluginDescription = "ADS-B aircraft traffic overlay"

    func activate(host: PluginHost) {
        // Hook 1: map overlay rendered in the engine-agnostic chrome on BOTH
        // engines. ADS-B's actual aircraft markers keep coming from the two
        // engines as a data array, so this overlay is an unobtrusive status
        // surface (default: nothing rendered) — guaranteeing zero visual
        // change vs the pre-plugin app.
        host.registerMapOverlay { AnyView(ADSBStatusOverlay()) }

        // Hook 2: settings row → settingsContent() (the existing full ADS-B
        // settings/list screen).
        host.registerSettingsRow(label: "ADS-B", icon: "airplane.circle.fill")
    }

    func deactivate() {
        // Bridge plugin-off → service-off, reusing the existing didSet →
        // stopTracking() semantics. This preserves the exact behavior of the
        // legacy ADS-B toggle.
        if ADSBTrafficService.shared.settings.isEnabled {
            var settings = ADSBTrafficService.shared.settings
            settings.isEnabled = false
            ADSBTrafficService.shared.settings = settings
        }
    }

    func settingsContent() -> AnyView? {
        // Reuse the existing settings/list view verbatim — no new UI.
        AnyView(ADSBTrafficView())
    }
}
