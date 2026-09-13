// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "swift-highway",
    products: [
        .library(name: "Highway", targets: ["Highway"])
    ],
    targets: [
        .target(
            name: "CHighway",
            path: "Sources/CHighway",
            publicHeadersPath: "include",
            cxxSettings: disabledTargets
        ),
        .target(
            name: "CHighwayOps",
            dependencies: ["CHighway"],
            publicHeadersPath: "include",
            cxxSettings: disabledTargets
        ),
        .target(
            name: "Highway",
            dependencies: ["CHighway", "CHighwayOps"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "HighwayTests",
            dependencies: ["Highway"],
            swiftSettings: settings
        ),
    ],
    cxxLanguageStandard: .cxx17
)

/// A sizeless vector has no Swift type to be imported as, so the targets whose vectors are
/// sizeless are turned off and their platforms use the widest fixed-size target they have.
///
/// This is a compiler define rather than a `#define` in the bridge header, because
/// `hwy/detect_targets.h` is a modular header that defaults the macro, so a header that set it
/// afterwards would disagree with the already-built module.
var disabledTargets: [CXXSetting] {
    [.define("HWY_DISABLED_TARGETS", to: "(HWY_ALL_SVE | HWY_RVV)")]
}

var settings: [SwiftSetting] {
    [
        .interoperabilityMode(.Cxx),
        .swiftLanguageMode(.v6),
        .strictMemorySafety(),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableExperimentalFeature("SafeInteropWrappers"),
    ]
}
