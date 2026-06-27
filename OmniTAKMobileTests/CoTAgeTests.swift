//
//  CoTAgeTests.swift
//  OmniTAKMobileTests
//
//  #178 — point-age bucketing + relative/short labels + staleness opacity.
//  Mirrors the Android CoTAgeTest so iOS and Android stay in lockstep on the
//  thresholds (fresh ≤1m, aging 1–5m, stale >5m) and label copy.
//

import XCTest
@testable import OmniTAK

final class CoTAgeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    // MARK: - Buckets

    func testBucketFresh() {
        XCTAssertEqual(CoTAge.bucket(age: 0), .fresh)
        XCTAssertEqual(CoTAge.bucket(age: 30), .fresh)
        XCTAssertEqual(CoTAge.bucket(age: 60), .fresh, "exactly 1m is still fresh (<=)")
    }

    func testBucketAging() {
        XCTAssertEqual(CoTAge.bucket(age: 61), .aging)
        XCTAssertEqual(CoTAge.bucket(age: 5 * 60), .aging, "exactly 5m is still aging (<=)")
    }

    func testBucketStale() {
        XCTAssertEqual(CoTAge.bucket(age: 5 * 60 + 1), .stale)
        XCTAssertEqual(CoTAge.bucket(age: 3600), .stale)
    }

    func testBucketNegativeAgeTreatedAsFresh() {
        // Clock skew (future timestamp) should not throw — reads fresh.
        XCTAssertEqual(CoTAge.bucket(age: -120), .fresh)
    }

    func testBucketFromReceivedAt() {
        XCTAssertEqual(CoTAge.bucket(receivedAt: ago(10), now: now), .fresh)
        XCTAssertEqual(CoTAge.bucket(receivedAt: ago(120), now: now), .aging)
        XCTAssertEqual(CoTAge.bucket(receivedAt: ago(600), now: now), .stale)
    }

    // MARK: - Opacity

    func testAlphaByBucket() {
        XCTAssertEqual(CoTAge.alpha(age: 30), CoTAge.alphaFresh, accuracy: 0.0001)
        XCTAssertEqual(CoTAge.alpha(age: 120), CoTAge.alphaAging, accuracy: 0.0001)
        XCTAssertEqual(CoTAge.alpha(age: 600), CoTAge.alphaStale, accuracy: 0.0001)
    }

    func testAlphaConstantsMatchAndroid() {
        XCTAssertEqual(CoTAge.alphaFresh, 1.0, accuracy: 0.0001)
        XCTAssertEqual(CoTAge.alphaAging, 0.7, accuracy: 0.0001)
        XCTAssertEqual(CoTAge.alphaStale, 0.4, accuracy: 0.0001)
    }

    // MARK: - Relative label

    func testRelativeJustNow() {
        XCTAssertEqual(CoTAge.relative(receivedAt: ago(0), now: now), "just now")
        XCTAssertEqual(CoTAge.relative(receivedAt: ago(9), now: now), "just now")
    }

    func testRelativeSeconds() {
        XCTAssertEqual(CoTAge.relative(receivedAt: ago(10), now: now), "10s ago")
        XCTAssertEqual(CoTAge.relative(receivedAt: ago(59), now: now), "59s ago")
    }

    func testRelativeMinutes() {
        XCTAssertEqual(CoTAge.relative(receivedAt: ago(60), now: now), "1m ago")
        XCTAssertEqual(CoTAge.relative(receivedAt: ago(240), now: now), "4m ago")
        XCTAssertEqual(CoTAge.relative(receivedAt: ago(59 * 60), now: now), "59m ago")
    }

    func testRelativeOverAnHour() {
        XCTAssertEqual(CoTAge.relative(receivedAt: ago(3600), now: now), ">1h")
        XCTAssertEqual(CoTAge.relative(receivedAt: ago(10_000), now: now), ">1h")
    }

    func testRelativeNilReceivedAt() {
        XCTAssertNil(CoTAge.relative(receivedAt: nil, now: now))
    }

    func testRelativeFutureReadsJustNow() {
        XCTAssertEqual(CoTAge.relative(receivedAt: now.addingTimeInterval(30), now: now), "just now")
    }

    // MARK: - Short label (map overlay)

    func testShortLabelUnderAMinute() {
        XCTAssertEqual(CoTAge.shortLabel(receivedAt: ago(0), now: now), "<1m")
        XCTAssertEqual(CoTAge.shortLabel(receivedAt: ago(59), now: now), "<1m")
    }

    func testShortLabelMinutes() {
        XCTAssertEqual(CoTAge.shortLabel(receivedAt: ago(60), now: now), "1m")
        XCTAssertEqual(CoTAge.shortLabel(receivedAt: ago(300), now: now), "5m")
    }

    func testShortLabelOverAnHour() {
        XCTAssertEqual(CoTAge.shortLabel(receivedAt: ago(3600), now: now), ">1h")
    }

    func testShortLabelNil() {
        XCTAssertNil(CoTAge.shortLabel(receivedAt: nil, now: now))
    }
}
