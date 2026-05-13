//
//  RemoteIdToPointMarkerConverter.swift
//  OmniTAKMobile
//
//  Convert a `RemoteIdTrack` (aggregated stream of OpenDroneID
//  messages from one drone) into a `PointMarker` the iOS map
//  pipeline already renders. Pure function, no I/O.
//
//  Mirrors the Android `RemoteIdToCoTConverter` — same cotType
//  mapping per UA Type so both clients render the drone with the
//  same MIL-STD-2525 symbol from the shared `cot_types.json`
//  catalogue (Phase D).
//

import Foundation
import CoreLocation

enum RemoteIdToPointMarkerConverter {

    /// Prefix every UID so detected drones are recognisable in the
    /// contacts list.
    private static let uidPrefix = "RID-"

    /// Map UA Type → CoT type. Drone class (multirotor) goes to
    /// `a-u-A-M-H-Q` so the catalogue's SUAPMHQ---- rotor symbol
    /// lights up; fixed-wing UAS use `a-u-A-M-F-Q` (SUAPMFQ----);
    /// everything else falls back to plain `a-u-A` (SUA---------).
    private static func cotType(for uaType: OpenDroneIdMessage.UaType) -> String {
        switch uaType {
        case .helicopterOrMultirotor:
            return "a-u-A-M-H-Q"
        case .aeroplane, .hybridLift, .glider, .gyroplane:
            return "a-u-A-M-F-Q"
        default:
            return "a-u-A"
        }
    }

    /// Convert a renderable track to a `PointMarker`. Returns nil
    /// if the track doesn't have a valid lat/lon yet.
    static func toPointMarker(_ track: RemoteIdTrack) -> PointMarker? {
        guard let loc = track.lastLocation, loc.hasValidPosition else { return nil }

        let coord = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
        let cotType = cotType(for: track.uaType)

        var remarks = "FAA Remote ID detection."
        remarks += " UA: \(track.uaType)"
        remarks += " / ID: \(track.idType)"
        if let alt = loc.geodeticAltitudeM {
            remarks += String(format: " / Alt: %.0f m MSL", alt)
        }
        if let agl = loc.heightAboveTakeoffM {
            remarks += String(format: " / AGL: %.0f m", agl)
        }
        if loc.groundSpeedMs > 0 {
            remarks += String(format: " / Speed: %.1f m/s", loc.groundSpeedMs)
        }
        remarks += " / Heading: \(loc.trackDirectionDeg)°"

        var marker = PointMarker(
            name: "DRONE-\(track.uasId)",
            affiliation: .unknown,
            coordinate: coord,
            altitude: loc.geodeticAltitudeM,
            remarks: remarks
        )
        marker.uid = uidPrefix + track.uasId
        marker.cotType = cotType
        return marker
    }
}
