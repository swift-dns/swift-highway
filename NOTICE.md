# Notice

## swift-highway

This product wraps [highway](https://github.com/google/highway), Google's portable SIMD
library, for Swift.

## Vendored code

`Sources/CHighway/include/hwy` is a verbatim copy of highway, taken at the tag recorded in
[highway-version.json](highway-version.json). It is not edited here: `scripts/vendor-highway.sh`
replaces the whole tree from upstream, and CI fails if the committed tree differs from what that
script produces.

highway is dual-licensed under your choice of the Apache License 2.0 or the BSD 3-Clause
License. Its license text is kept alongside the copy, at
[Sources/CHighway/LICENSE](Sources/CHighway/LICENSE), and is also this package's
[LICENSE](LICENSE).

    Copyright 2019 Google LLC
    SPDX-License-Identifier: Apache-2.0
    SPDX-License-Identifier: BSD-3-Clause
