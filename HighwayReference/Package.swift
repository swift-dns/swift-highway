// swift-tools-version: 6.3

// MARK: - BEGIN exact copy of the main package's Package.swift
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
        .treatAllWarnings(as: .error),
    ]
}
// MARK: - END exact copy of the main package's Package.swift

// MARK: - Add reference stuff now

package.targets += [
    .target(
        name: "CHighway",
        path: "CHighway",
        publicHeadersPath: "include",
        cxxSettings: disabledTargets
    ),
    .target(
        name: "CHighwayReference",
        dependencies: ["CHighway"],
        path: "CHighwayReference",
        publicHeadersPath: "include",
        cxxSettings: disabledTargets
    ),
]

package.cxxLanguageStandard = .cxx17

/// A sizeless vector has no Swift type to be imported as, so the targets whose vectors are
/// sizeless are turned off and their platforms use the widest fixed-size target they have.
///
/// This is a compiler define rather than a `#define` in the bridge header, because
/// `hwy/detect_targets.h` is a modular header that defaults the macro, so a header that set it
/// afterwards would disagree with the already-built module.
var disabledTargets: [CXXSetting] {
    [.define("HWY_DISABLED_TARGETS", to: "(HWY_ALL_SVE | HWY_RVV)")]
}
