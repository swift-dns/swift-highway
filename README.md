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

[highway](https://github.com/google/highway)'s portable SIMD ops for Swift, with no C++ to configure.

Supports `Darwin` (`Apple` platforms), `Linux` (including `Android`), `Windows`, `FreeBSD`, `OpenBSD`[^1], `WASI`, embedded, and more.

[^1]: Swift support for `OpenBSD` is a work-in-progress. This library doesn't have CI for `OpenBSD` yet, so things can be flaky.

## Using swift-highway

Add the dependency to the target that wants it. No settings are needed, neither in your package nor in the packages that depend on yours:

```diff
dependencies: [
+    .package(url: "https://github.com/swift-dns/swift-highway.git", exact: "1.0.0-alpha.8")
],
targets: [
    .target(
        name: "MyLibrary",
+        dependencies: [.product(name: "Highway", package: "swift-highway")]
    )
]
```

Each element type has its own namespace of ops, such as `HighwayUInt8`, and `HighwayElement` lets a kernel be written once for all of them:

```swift
import Highway

func count(of needle: UInt8, in bytes: UnsafeBufferPointer<UInt8>) -> Int {
    let target = HighwayUInt8.repeating(needle)
    var count = 0
    var index = 0
    while index + HighwayUInt8.laneCount <= bytes.count {
        let vector = HighwayUInt8.load(from: bytes.baseAddress! + index)
        count += HighwayUInt8.trueCount(HighwayUInt8.equalTo(vector, target))
        index += HighwayUInt8.laneCount
    }
    return bytes[index...].reduce(count) { $0 + ($1 == needle ? 1 : 0) }
}
```

## Which target you get

The ops are compiled for a static target, the best one the compiler was told it could use.

| Platform | Target | Description                                                                                                                           |
| -------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| arm64    | NEON   | NEON is baseline, so no flags are needed.                                                                                             |
| x86_64   | SSE2   | The baseline, or SSSE3 on Apple platforms and Android. For SSE4, pass `-Xcc -march=x86-64-v2`. AVX2 and AVX-512 builds use the SSE4 ops. |
| Others   | EMU128 | Portable C, which the compiler lowers to the SIMD the platform has, such as WASM SIMD, VSX or RVV, or to scalar code.                |

`Highway.targetName` reports what was chosen, and `Highway.isEmulated` is true where the portable
ops have no SIMD to lower to, so scalar code is faster.

## How it relates to highway

Every op reproduces what highway does on the same target, down to NaN payloads and the results of
out-of-range inputs, so the ops behave like highway's. `HighwayReference/` holds a copy of highway
and generated tests that compare every op with highway's, lane for lane, on NEON, SSE2, SSSE3, SSE4
and highway's EMU128.

The one deliberate difference is `firstLanes(count:)` on NEON, which selects every lane for any
count of at least `laneCount`, as highway's x86 and EMU128 ops do. Highway's NEON op wraps counts
above the lane type's signed maximum.

## What is not wrapped

swift-highway wraps Highway's SIMD ops only. The libraries Highway builds on top of them, such as
`vqsort`, `thread_pool`, `image`, `matvec`, `bit_pack`, `btree`, `unroller`, the `iguana` and
`range_coder` codecs, `profiler` and `nanobenchmark`, are out of scope.
