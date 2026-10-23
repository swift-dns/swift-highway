// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "swift-highway",
    products: [
        .library(name: "Highway", targets: ["Highway"])
    ],
    targets: [
        .target(
            name: "CHighwayOps",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Highway",
            dependencies: ["CHighwayOps"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "HighwayTests",
            dependencies: ["Highway"],
            swiftSettings: settings
        ),
    ]
)

var settings: [SwiftSetting] {
    [
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableExperimentalFeature("SafeInteropWrappers"),
        .enableExperimentalFeature(
            "AvailabilityMacro=SwiftStdlib 5.1:macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0"
        ),
    ]
}
