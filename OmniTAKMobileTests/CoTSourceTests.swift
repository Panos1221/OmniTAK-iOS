//
//  CoTSourceTests.swift
//  OmniTAKMobileTests
//
//  #180 — data-source labels for the marker / contact detail sheet.
//  Mirrors the Android CoTSourceTest so the labels match across platforms:
//  "TAK: <server>", "Mesh: Meshtastic", "Mesh: MeshCore", "Local".
//

import XCTest
@testable import OmniTAK

final class CoTSourceTests: XCTestCase {

    func testTakServerWithName() {
        XCTAssertEqual(CoTSource.takServer("HQ-Server").label, "TAK: HQ-Server")
    }

    func testTakServerWithoutName() {
        XCTAssertEqual(CoTSource.takServer(nil).label, "TAK server")
    }

    func testTakServerBlankNameFallsBack() {
        // Blank/whitespace endpoint is treated as absent.
        XCTAssertEqual(CoTSource.takServer("   ").label, "TAK server")
        XCTAssertEqual(CoTSource.takServer("").label, "TAK server")
    }

    func testMeshMeshtastic() {
        XCTAssertEqual(CoTSource.mesh("Meshtastic").label, "Mesh: Meshtastic")
    }

    func testMeshMeshCore() {
        XCTAssertEqual(CoTSource.mesh("MeshCore").label, "Mesh: MeshCore")
    }

    func testMeshWithoutFramework() {
        XCTAssertEqual(CoTSource.mesh(nil).label, "Mesh")
    }

    func testLocal() {
        XCTAssertEqual(CoTSource.local.label, "Local")
    }

    func testOtherWithDetail() {
        XCTAssertEqual(CoTSource(transport: .other, detail: "Plugin").label, "Plugin")
    }

    func testOtherWithoutDetail() {
        XCTAssertEqual(CoTSource(transport: .other).label, "Other")
    }

    func testBlankDetailNormalizedToNil() {
        XCTAssertNil(CoTSource(transport: .mesh, detail: "  ").detail)
    }

    func testEquatable() {
        XCTAssertEqual(CoTSource.mesh("Meshtastic"), CoTSource.mesh("Meshtastic"))
        XCTAssertNotEqual(CoTSource.mesh("Meshtastic"), CoTSource.mesh("MeshCore"))
        XCTAssertNotEqual(CoTSource.takServer("A"), CoTSource.local)
    }
}
