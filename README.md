# swift-highway

Swift bindings for [highway](https://github.com/google/highway), Google's portable SIMD library.

## Which target you get

The ops are compiled in Highway's static dispatch mode, so they use the best target the compiler
was told it could use.

| Platform | Target | Description                                                                |
| -------- | ------ | -------------------------------------------------------------------------- |
| arm64    | NEON   | NEON is baseline, so this is the full width the processor has.             |
| x86_64   | SSE2   | The baseline. For AVX2 or AVX-512, pass `-Xcc -march=x86-64-v3` or better. |

`Highway.targetName` reports what was chosen, and `Highway.isEmulated` is true on the targets
that only emulate vectors, where scalar code is faster.

Sorting is unaffected by all of this and always dispatches at run time.

SVE and RVV are disabled: their vectors are sizeless, so they have no Swift type to be imported
as. The platforms that have them use the widest fixed-size target they have instead.

## What is not wrapped

`thread_pool`, `image`, `matvec`, the `iguana` and `range_coder` codecs, `bit_pack`, `btree`,
`profiler` and `nanobenchmark` are not exposed yet. Neither are the `float16_t`, `K32V32`,
`K64V64` and `uint128_t` sort keys, which need Swift types to sort first.

`unroller` is a C++ template framework for C++ authors and is not wrappable in principle.
