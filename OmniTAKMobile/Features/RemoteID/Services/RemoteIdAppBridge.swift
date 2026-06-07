//
//  RemoteIdAppBridge.swift
//  OmniTAKMobile
//
//  Adapter that connects `RemoteIdScanner`'s track stream to the
//  iOS marker pipeline. Owned by `OmniTAKMobileApp` and configured
//  once at launch; the @AppStorage("remoteIdScanEnabled") toggle
//  in Settings flips the underlying scanner on and off.
//
//  Companion to the Android `OmniTAKApp` lifecycle wiring — both
//  platforms maintain the same on/off semantics and the same
//  per-drone `RID-{uasId}` UID convention so server-side
//  deduplication works regardless of which client saw the drone
//  first.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class RemoteIdAppBridge: ObservableObject {

    static let shared = RemoteIdAppBridge()

    /// Underlying scanner. Exposed read-only so callers can peek at
    /// `scanner.tracks` (e.g. for a diagnostics screen) without
    /// being able to start/stop it directly — toggling is done via
    /// `setEnabled` so the @AppStorage flag stays in sync.
    let scanner: RemoteIdScanner

    private var enabled: Bool = false
    private let markerStore: PointDropperService

    private init() {
        self.scanner = RemoteIdScanner()
        self.markerStore = PointDropperService.shared
        // The scanner contract says it calls onTrackUpdate on main, and
        // the BLE delegate sites honor that (queue: .main). The stale-
        // purge Timer adds to whichever run loop start() was called from
        // and, under heavy 3D-globe interaction, can fire when main
        // isn't in its default mode — observed in syslog as SwiftUICore
        // `Publishing changes from background threads is not allowed`.
        // Hop to main explicitly so any future contract drift can't
        // crash the app the way the prior PPLI off-main publish did
        // (commit 7e41060). Pattern matches that fix verbatim.
        self.scanner.onTrackUpdate = { [weak self] update in
            DispatchQueue.main.async { [weak self] in
                self?.applyUpdate(update)
            }
        }
    }

    /// Mirror the @AppStorage value into the scanner. Idempotent.
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value {
            scanner.start()
        } else {
            scanner.stop()
        }
    }

    // MARK: - External detector ingest (gyb)

    /// Inject a track from an external detector (the gyb WiFi-RID sensor over
    /// BLE GATT) into the same marker pipeline as the on-device BLE scanner.
    /// Because the UID is `RID-{uasId}`, a drone the gyb sees over WiFi and
    /// the phone sees over BLE collapses to one marker — automatic dedup.
    /// `sourceNote` is appended to the remarks (e.g. " / via gyb (WiFi
    /// beacon)") so the operator can tell how the drone was caught.
    func ingestExternalTrack(_ track: RemoteIdTrack, sourceNote: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        upsertMarker(for: track, sourceNote: sourceNote)
    }

    /// Drop an external detector's marker (stale purge / detector toggled off).
    func removeExternalTrack(uasId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        removeMarker(uasId: uasId)
    }

    // MARK: - Marker synchronization

    private func applyUpdate(_ update: RemoteIdTrackUpdate) {
        // Belt-and-suspenders: applyUpdate mutates `markerStore.markers`
        // which is @Published. SwiftUI observers crash if mutations
        // arrive off-main. Any future call site that forgets to hop
        // will trip this assertion in debug instead of corrupting
        // observers in release.
        dispatchPrecondition(condition: .onQueue(.main))
        for uasId in update.changedUasIds {
            if let track = scanner.tracks.first(where: { $0.uasId == uasId }) {
                upsertMarker(for: track)
            } else {
                removeMarker(uasId: uasId)
            }
        }
    }

    // Detected drones are LIVE CONTACTS, not dropped pins — publish them
    // through the CoT pipeline (TAKService.cotEvents) so they render with the
    // proper MIL-STD-2525 air symbol (rotary/fixed-wing) and federate to
    // connected TAK servers, exactly like the Android ContactStore path. The
    // earlier PointDropperService route drew an affiliation-only "yellow
    // circle" that ignored the air dimension entirely.
    private func upsertMarker(for track: RemoteIdTrack, sourceNote: String? = nil) {
        // Emit the drone marker (when it has a valid GPS fix) AND/OR the
        // operator (pilot) marker (whenever the operator location is valid).
        // When the drone has no GPS yet, the pilot still plots — that's the
        // fix for the invisible-detection bug.
        if let loc = track.lastLocation, loc.hasValidPosition {
            let event = Self.makeDroneCoTEvent(track: track, loc: loc, sourceNote: sourceNote)
            CoTEventHandler.shared.handle(event: .positionUpdate(event))
        }
        if let op = track.lastOperatorLocation, op.hasValidPosition {
            let event = Self.makeOperatorCoTEvent(track: track, op: op, sourceNote: sourceNote)
            CoTEventHandler.shared.handle(event: .positionUpdate(event))
        }
    }

    private func removeMarker(uasId: String) {
        // Promptly drop both the drone and operator contacts (RID stale purge
        // is ~30 s) instead of waiting for the 1-hour CoT staleness backstop.
        CoTEventHandler.shared.removeEvent(uid: "RID-" + uasId)
        CoTEventHandler.shared.removeEvent(uid: "RID-OP-" + uasId)
    }

    /// UA Type → CoT type. Multirotor → `a-u-A-M-H-Q` (rotary), fixed-wing
    /// classes → `a-u-A-M-F-Q`, else plain `a-u-A`. Matches the Android
    /// RemoteIdToCoTConverter so both clients render the same symbol and
    /// server-side dedup works.
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

    private static func makeDroneCoTEvent(
        track: RemoteIdTrack,
        loc: OpenDroneIdMessage.Location,
        sourceNote: String?
    ) -> CoTEvent {
        var remarks = "FAA Remote ID detection."
        remarks += " UA: \(track.uaType) / ID: \(track.idType)"
        if let alt = loc.geodeticAltitudeM { remarks += String(format: " / Alt: %.0f m MSL", alt) }
        if let agl = loc.heightAboveTakeoffM { remarks += String(format: " / AGL: %.0f m", agl) }
        if loc.groundSpeedMs > 0 { remarks += String(format: " / Speed: %.1f m/s", loc.groundSpeedMs) }
        remarks += " / Heading: \(loc.trackDirectionDeg)°"
        if let op = track.lastOperatorLocation, op.hasValidPosition {
            remarks += " / Pilot: PILOT-\(track.uasId)"
        }
        if let note = sourceNote { remarks += note }

        let point = CoTPoint(
            lat: loc.latitude,
            lon: loc.longitude,
            hae: loc.geodeticAltitudeM ?? 0,
            ce: loc.horizontalAccuracyM ?? 9_999_999,
            le: loc.verticalAccuracyM ?? 9_999_999
        )
        let detail = CoTDetail(
            callsign: "DRONE-\(track.uasId)",
            team: nil,
            teamRole: nil,
            speed: loc.groundSpeedMs,
            course: Double(loc.trackDirectionDeg),
            remarks: remarks,
            battery: nil,
            device: "Remote ID",
            platform: "OmniTAK"
        )
        return CoTEvent(
            uid: "RID-\(track.uasId)",
            type: cotType(for: track.uaType),
            time: Date(),
            point: point,
            detail: detail
        )
    }

    /// Operator (pilot) marker. Unknown-ground (`a-u-G`) so the operator can
    /// promote affiliation; plots wherever the RID System message reports the
    /// pilot, even before the drone itself has GPS. Matches Android's
    /// `RemoteIdToCoTConverter.operatorCoT` UID/type/callsign exactly.
    private static func makeOperatorCoTEvent(
        track: RemoteIdTrack,
        op: OpenDroneIdMessage.OperatorLocation,
        sourceNote: String?
    ) -> CoTEvent {
        var remarks = "FAA Remote ID operator (pilot) location."
        remarks += " Drone: DRONE-\(track.uasId)"
        if track.lastLocation?.hasValidPosition != true {
            remarks += " / drone GPS not yet acquired"
        }
        if let note = sourceNote { remarks += note }

        let point = CoTPoint(
            lat: op.latitude,
            lon: op.longitude,
            hae: op.altitudeM ?? 0,
            ce: 9_999_999,
            le: 9_999_999
        )
        let detail = CoTDetail(
            callsign: "PILOT-\(track.uasId)",
            team: nil,
            teamRole: nil,
            speed: 0,
            course: 0,
            remarks: remarks,
            battery: nil,
            device: "Remote ID",
            platform: "OmniTAK"
        )
        return CoTEvent(
            uid: "RID-OP-\(track.uasId)",
            type: "a-u-G",
            time: Date(),
            point: point,
            detail: detail
        )
    }
}
