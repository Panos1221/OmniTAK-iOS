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
    /// Operator (pilot) location, when broadcast. Often present before
    /// the drone has a GPS fix, so it can be the only plottable point we
    /// have — that's what fixes the "invisible detection" bug.
    var lastOperatorLocation: OpenDroneIdMessage.OperatorLocation? = nil

    /// True when we have an identifier and at least one plottable point —
    /// the drone's own GPS, or the operator/pilot location.
    var isRenderable: Bool {
        !uasId.isEmpty &&
            (lastLocation?.hasValidPosition == true ||
             lastOperatorLocation?.hasValidPosition == true)
    }
}
