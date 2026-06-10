// swift-tools-version:5.7
//
// OmniTAKMobileSpecs — standalone Swift Package that hosts pure-logic
// XCTest suites for OmniTAK Mobile (iOS).
//
// The main OmniTAKMobile.xcodeproj now has a real OmniTAKMobileTests
// unit-test target (hosted in the app, run via `xcodebuild test`); this
// package remains for pure-logic suites that benefit from fast, host-free
// `swift test` iteration (e.g. lasso point-in-polygon). Run with:
//
//   cd OmniTAKMobileSpecs && swift test
//
import PackageDescription

let package = Package(
    name: "OmniTAKMobileSpecs",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "LassoCore", targets: ["LassoCore"])
    ],
    targets: [
        .target(
            name: "LassoCore",
            path: "Sources/LassoCore"
        ),
        .testTarget(
            name: "LassoCoreTests",
            dependencies: ["LassoCore"],
            path: "Tests/LassoCoreTests"
        )
    ]
)
