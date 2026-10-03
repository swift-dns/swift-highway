<p>
    <a href="https://github.com/swift-dns/swift-highway/actions/workflows/unit-tests.yml">
        <img
            src="https://img.shields.io/github/actions/workflow/status/swift-dns/swift-highway/unit-tests.yml?event=push&style=plastic&logo=github&label=unit-tests&logoColor=%23ccc"
            alt="Unit Tests CI"
        >
    </a>
    <a href="https://swift.org">
        <img
            src="https://design.vapor.codes/images/swift63up.svg"
            alt="Swift 6.3+"
        >
    </a>
</p>

# swift-highway

Swift bindings for [highway](https://github.com/google/highway), Google's portable SIMD library.

Supports `Darwin` (`Apple` platforms), `Linux` (including `Android`), `Windows`, `FreeBSD`, `OpenBSD`[^1], and more.   
Also compiles on embedded and `WASI`, but no actual functionality is available on those platforms, see below.

[^1]: Swift support for `OpenBSD` is a work-in-progress. This library doesn't have CI for `OpenBSD` yet, so things can be flaky.

## Using swift-highway

Highway is a `C++` library, so a target that imports it needs C++ interoperability turned on.

That setting currently comes with a few catches that you might need to take care of.

### Package.swift

Using `swift-highway` will require some changes like the following:

```diff
dependencies: [
      /// Depend on `swift-highway`
+    .package(url: "https://github.com/swift-dns/swift-highway.git", exact: "1.0.0-alpha.3")
],
targets: [
    .target(
        name: "MyLibrary",
         /// Add the dependency to the target that wants it
+        dependencies: [.product(name: "Highway", package: "swift-highway")],
         /// Add the interoperability settings to the target
+        swiftSettings: interoperabilitySettings
    ),
    .testTarget(
        name: "MyLibraryTests",
        dependencies: ["MyLibrary"],
+        swiftSettings: interoperabilitySettings
    )
]

/// Enable C++ interoperability for the target
+var interoperabilitySettings: [SwiftSetting] {
+    [.interoperabilityMode(.Cxx, .when(platforms: highwayPlatforms))]
+}

/// The platforms swift-highway package currently supports.
/// WASI is left out because its SDK cycles through the libc++ module map under C++ interoperability.
/// Embedded platforms miss some C headers that swift-highway currently requires.
/// You can trim the following list to the minimum you need, but keep the condition itself.
+var highwayPlatforms: [Platform] {
+    [
+        .macOS,
+        .macCatalyst,
+        .iOS,
+        .tvOS,
+        .watchOS,
+        .visionOS,
+        .driverKit,
+        .linux,
+        .android,
+        .windows,
+        .openbsd,
+        // `Platform.freebsd` is not available to any released tools version yet.
+        .custom("freebsd"),
+    ]
+}
```

Two things about that are not obvious:

* Every target that transitively imports a Highway-using module needs the setting too, test targets
  included. Without it they fail with `module 'CHighway' requires feature 'cplusplus'`.
* Keep the setting conditional even if you don't target WASI yourself. SwiftPM's synthesized test
  discovery module copies `-cxx-interoperability-mode` out of any module in the dependency graph,
  whether or not that module is built for the platform being compiled, so an unconditional setting
  turns interoperability on for WASI too. A plain `swift build` doesn't hit it, but
  `swift build --build-tests` does:

```
error: cyclic dependency in module 'SwiftWASILibc': SwiftWASILibc -> std_inttypes_h -> SwiftWASILibc
```

### Using the API

If you support Embedded or WASI platforms, you need to guard swift-highway uses and keep a fallback:

```swift
#if !($Embedded || os(WASI))
internal import Highway
#endif

func smallest(in values: UnsafePointer<UInt32>, count: Int) -> UInt32 {
    #if $Embedded || os(WASI)
    // A plain loop or something that LLVM auto-vectorizes on its own.
    #else
    // The swift-highway version.
    #endif
}
```

* `public import` can't be used until Swift 6.5 is released, otherwise the Swift compiler trips into an error.
  * Prefer to use `internal import` instead.
  * Performance-wise this shouldn't have many implications; most vectorized code doesn't benefit from inlining.
  * If you need _some_ inlining, wrap the vectorized code in a separate function marked with `@usableFromInline`.

If you bump into an error like the following:

```
error: enum 'HighwayUInt32' is internal and cannot be referenced from an '@inlinable' function
```

Mark the function as `@usableFromInline` instead.

### Android

The Android SDK points clang's resource dir at the NDK's clang.   
The NDK's clang builtin headers are rejected by Swift toolchain's clang with `could not build module '_Builtin_intrinsics'`.   
When building for Android, point the resource dir back at the toolchain's own `<toolchain>/usr/lib/swift/clang`:

```bash
-Xcc -resource-dir -Xcc "$(swiftc -print-target-info | jq -r .paths.runtimeResourcePath)/clang"
```

### Building tests

If your test-builds are failing, try disabling XCTest by passing `--disable-xctest` everywhere tests are built or run:

```
swift build --build-tests --disable-xctest
swift test --disable-xctest
```

That is enough when only your library imports Highway.
If a test target imports swift-highway directly, the synthesized swift-testing entry point still drops the C++ interoperability mode, so pass it on the command line as well:

```
-Xswiftc -cxx-interoperability-mode=default
```

## Which target you get

The ops are compiled in Highway's static dispatch mode, so they use the best target the compiler
was told it could use.

| Platform | Target | Description                                                                                                             |
| -------- | ------ | ----------------------------------------------------------------------------------------------------------------------- |
| arm64    | NEON   | NEON is baseline, so no flags are needed.                                                                               |
| x86_64   | SSE2   | The baseline, or SSSE3 on Apple platforms and Android. For SSE4, pass `-Xcc -march=x86-64-v2 -Xcc -maes -Xcc -mpclmul`. |

Highway needs AES and PCLMUL for SSE4 and above, and no `x86-64-v*` level includes them.

`Highway.targetName` reports what was chosen, and `Highway.isEmulated` is true on the targets
that only emulate vectors, where scalar code is faster.

Sorting is unaffected by all of this and always dispatches at run time.

SVE and RVV are disabled: their vectors are sizeless, so they have no Swift type to be imported
as. The platforms that have them use the widest fixed-size target they have instead.

AVX2 and AVX-512 are unavailable as well: their vectors are aligned to more than 16 bytes, which
Swift does not import, so flags that select them fail to build.

## What is not wrapped

`thread_pool`, `image`, `matvec`, the `iguana` and `range_coder` codecs, `bit_pack`, `btree`,
`profiler` and `nanobenchmark` are not exposed yet. Neither are the `float16_t`, `K32V32`,
`K64V64` and `uint128_t` sort keys, which need Swift types to sort first.

`unroller` is a C++ template framework for C++ authors and is not wrappable in principle.
