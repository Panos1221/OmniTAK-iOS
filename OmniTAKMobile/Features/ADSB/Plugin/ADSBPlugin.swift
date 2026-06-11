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

    // Symmetric-toggle state. When deactivate() turns the overlay off it
    // stashes the prior `isEnabled` so activate() can restore the exact state
    // the user left it in — disable-then-reenable must be a no-op for the
    // overlay's visibility. `nil` means "never stashed" (first activation),
    // which restores to the default-ON state matching the plugin's
    // default-enabled posture and ADSBTrafficSettings.isEnabled = true.
    private var stashedOverlayEnabled: Bool?

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

        // Restore the overlay to the state it was in BEFORE the plugin was
        // disabled. We deliberately do NOT force isEnabled = true: a user who
        // intentionally hid aircraft via the inner "Show aircraft on map"
        // toggle (while leaving the plugin enabled) must not have that choice
        // clobbered here or on every launch. First activation (nil stash)
        // defaults ON to match the plugin's default-enabled state.
        let restore = stashedOverlayEnabled ?? true
        if ADSBTrafficService.shared.settings.isEnabled != restore {
            var settings = ADSBTrafficService.shared.settings
            settings.isEnabled = restore
            ADSBTrafficService.shared.settings = settings
        }
    }

    func deactivate() {
        // Bridge plugin-off → service-off, reusing the existing didSet →
        // stopTracking() semantics. Remember the prior enabled state first so
        // a later activate() can restore it — keeping the toggle symmetric.
        stashedOverlayEnabled = ADSBTrafficService.shared.settings.isEnabled
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
