//
//  RemoteIdTrackStore.swift
//  OmniTAKMobile
//
//  In-memory roster of `RemoteIdTrack`s keyed by UAS ID. Pure logic,
//  no CoreBluetooth dependency. Mirrors the Android
//  `RemoteIdTrackStore` semantics:
//
//    1. Merge Basic ID + Location for the same drone (whether they
//       arrive in one BT5 Message Pack or successive BT4 frames).
//    2. Use a per-MAC fallback ID when a frame arrives without Basic
//       ID — the next BasicID broadcast resolves the real UAS ID.
//    3. Drop tracks that haven't been heard from in `staleAfterMs`
//       so the map doesn't accumulate ghosts.
//

import Foundation

final class RemoteIdTrackStore {

    private let staleAfterMs: Int64
    private let clock: () -> Int64
    private var tracks: [String: RemoteIdTrack] = [:]

    init(
        staleAfterMs: Int64 = 30_000,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.staleAfterMs = staleAfterMs
        self.clock = clock
    }

    /// Snapshot of the current tracks.
    func snapshot() -> [RemoteIdTrack] { Array(tracks.values) }

    /// Pull a single track by its UAS ID; nil if unknown.
    func get(_ uasId: String) -> RemoteIdTrack? { tracks[uasId] }

    /// Drop everything — used on scanner stop / app reset.
    func clear() {
        tracks.removeAll()
    }

    /// Feed in a list of messages decoded from one BLE frame and
    /// return the set of UAS IDs whose tracks changed in a way the
    /// map should re-render. Empty set means nothing to do.
    ///
    /// - Parameter messages: decoded messages from one advertisement
    /// - Parameter fallbackId: when no Basic ID is in this frame,
    ///   attribute the Location to this stable key (typically the
    ///   BLE peer's MAC) so partial broadcasts still produce a
    ///   plottable track until the next Basic ID arrives.
    @discardableResult
    func ingest(_ messages: [OpenDroneIdMessage], fallbackId: String? = nil) -> Set<String> {
        guard !messages.isEmpty else { return [] }

        var basic: (idType: OpenDroneIdMessage.IdType, uaType: OpenDroneIdMessage.UaType, uasId: String)?
        var location: OpenDroneIdMessage.Location?

        for msg in messages {
            switch msg {
            case let .basicId(_, idType, uaType, uasId):
                if basic == nil {
                    basic = (idType, uaType, uasId)
                }
            case let .location(loc):
                if location == nil { location = loc }
            case .unknown:
                continue
            }
        }

        let uasId = basic?.uasId ?? fallbackId ?? ""
        guard !uasId.isEmpty else { return [] }

        let now = clock()
        let previous = tracks[uasId]

        let updated = RemoteIdTrack(
            uasId: uasId,
            uaType: basic?.uaType ?? previous?.uaType ?? .undeclared,
            idType: basic?.idType ?? previous?.idType ?? .none,
            lastLocation: location ?? previous?.lastLocation,
            lastUpdateMs: now
        )

        let changed: Bool
        if let previous = previous {
            changed = previous.lastLocation != updated.lastLocation
                || previous.uaType != updated.uaType
        } else {
            changed = true
        }

        tracks[uasId] = updated
        return changed ? [uasId] : []
    }

    /// Remove tracks last updated more than `staleAfterMs` ago.
    /// Returns the set of UAS IDs that were removed so callers can
    /// tell the marker store to drop their map annotations.
    func purgeStale() -> Set<String> {
        let now = clock()
        let staleIds = tracks
            .filter { now - $0.value.lastUpdateMs > staleAfterMs }
            .map { $0.key }
        staleIds.forEach { tracks.removeValue(forKey: $0) }
        return Set(staleIds)
    }
}
