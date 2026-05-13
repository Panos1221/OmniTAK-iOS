//
//  RemoteIdTrack.swift
//  OmniTAKMobile
//
//  Live state of one drone being tracked, aggregated across the
//  stream of OpenDroneID messages the scanner sees. Mirrors the
//  Android `RemoteIdTrack` data class so the cross-platform pipeline
//  agrees on the per-drone shape.
//

import Foundation

struct RemoteIdTrack: Equatable {
    /// Stable identifier — the UAS ID from Basic ID.
    let uasId: String
    let uaType: OpenDroneIdMessage.UaType
    let idType: OpenDroneIdMessage.IdType
    let lastLocation: OpenDroneIdMessage.Location?
    /// Wall-clock time of the last update.
    let lastUpdateMs: Int64

    /// True when we have both an identifier and a valid lat/lon —
    /// enough to render on the map.
    var isRenderable: Bool {
        !uasId.isEmpty && lastLocation?.hasValidPosition == true
    }
}
