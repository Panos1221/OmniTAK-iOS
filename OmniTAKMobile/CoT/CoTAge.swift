//
//  CoTAge.swift
//  OmniTAKMobile
//
//  #178 — Point-age formatting + staleness bucketing for received CoT events.
//
//  Field tester: "Sometimes I take my guys' position for granted not knowing the
//  info is ~4 min old." This turns the wall-clock gap between now and when a
//  point was last received into (a) a short relative-time label for the detail
//  sheet and (b) a coarse freshness bucket the map overlay fades a stale point by.
//
//  Everything here is a pure function of two times so it unit-tests without a
//  clock — callers pass `Date()` (or a `TimeInterval` age) explicitly. Ported
//  one-to-one from the Android CoTAge object so labels/thresholds match.
//

import Foundation

/// Pure point-age helpers. No instance state — all members are static.
enum CoTAge {
    /// Freshness buckets a received point falls into as it ages.
    enum Bucket {
        case fresh
        case aging
        case stale
    }

    // Thresholds (constants, per the spec): fresh < 1m, aging 1–5m, stale > 5m.
    static let freshMax: TimeInterval = 60            // 1 minute
    static let agingMax: TimeInterval = 5 * 60        // 5 minutes

    /// Map-opacity (alpha 0...1) applied to a point by its freshness bucket.
    static let alphaFresh: Double = 1.0
    static let alphaAging: Double = 0.7
    static let alphaStale: Double = 0.4

    /// Bucket for an age in seconds. Negative ages (clock skew — a future
    /// timestamp) are treated as fresh rather than throwing.
    static func bucket(age: TimeInterval) -> Bucket {
        if age <= freshMax { return .fresh }
        if age <= agingMax { return .aging }
        return .stale
    }

    /// Convenience: bucket from a received-at timestamp relative to `now`.
    static func bucket(receivedAt: Date, now: Date) -> Bucket {
        bucket(age: now.timeIntervalSince(receivedAt))
    }

    /// Map opacity for an age in seconds, by bucket.
    static func alpha(age: TimeInterval) -> Double {
        switch bucket(age: age) {
        case .fresh: return alphaFresh
        case .aging: return alphaAging
        case .stale: return alphaStale
        }
    }

    /// Map opacity for a received-at timestamp relative to `now`.
    static func alpha(receivedAt: Date, now: Date) -> Double {
        alpha(age: now.timeIntervalSince(receivedAt))
    }

    /// Short relative-time label for `receivedAt` as of `now`:
    ///   "just now"  (< 10s)
    ///   "Ns ago"    (< 1m)
    ///   "Nm ago"    (< 1h)
    ///   ">1h"       (>= 1h)
    /// A future timestamp (clock skew) reads "just now". Returns nil when
    /// `receivedAt` is nil (we never received it / unknown).
    static func relative(receivedAt: Date?, now: Date) -> String? {
        guard let receivedAt else { return nil }
        let age = now.timeIntervalSince(receivedAt)
        if age < 10 { return "just now" }
        if age < 60 { return "\(Int(age))s ago" }
        if age < 60 * 60 { return "\(Int(age / 60))m ago" }
        return ">1h"
    }

    /// Compact label for the on-map overlay (no "ago"): "<1m", "Nm", ">1h".
    static func shortLabel(receivedAt: Date?, now: Date) -> String? {
        guard let receivedAt else { return nil }
        let age = now.timeIntervalSince(receivedAt)
        if age < 60 { return "<1m" }
        if age < 60 * 60 { return "\(Int(age / 60))m" }
        return ">1h"
    }
}
