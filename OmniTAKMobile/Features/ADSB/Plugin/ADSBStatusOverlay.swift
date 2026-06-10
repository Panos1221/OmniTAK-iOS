//
//  ADSBStatusOverlay.swift
//  OmniTAKMobile
//
//  The map-overlay surface the ADS-B reference plugin registers. Aircraft
//  markers themselves are NOT drawn here — they keep flowing as the
//  `[Aircraft]` data array into the two map engines. This overlay renders
//  NOTHING (EmptyView) so the refactor is a guaranteed zero-visual-change.
//
//  It exists to demonstrate the `registerMapOverlay` hook with a real plugin
//  surface mounted in the engine-agnostic chrome on BOTH engines. A plugin
//  author can replace the body with their own markers/HUD.
//

import SwiftUI

struct ADSBStatusOverlay: View {
    var body: some View {
        // Intentionally empty — ADS-B's aircraft render via the engines'
        // data-array path; this keeps the visual output byte-identical.
        EmptyView()
    }
}
