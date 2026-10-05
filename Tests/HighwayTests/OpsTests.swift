#if !$Embedded && !os(WASI)
import Highway
import Testing

@Suite("Ops")
struct OpsTests {
    @Test("A vector survives a store after a load")
    func loadStoreRoundTrip() {
        typealias H = HighwayUInt8
        let lanes = H.laneCount
        let input = (0..<lanes).map { UInt8($0 &* 3) }
        var output = [UInt8](repeating: 0, count: lanes)

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                unsafe H.store(H.load(from: source.baseAddress!), to: destination.baseAddress!)
            }
        }

        #expect(output == input)
    }

    @Test("Arithmetic matches the scalar result")
    func arithmetic() {
        typealias H = HighwayInt32
        let lanes = H.laneCount
        let a = (0..<lanes).map { Int32($0) - 4 }
        let b = (0..<lanes).map { Int32($0) * 3 }

        var sum = [Int32](repeating: 0, count: lanes)
        var product = [Int32](repeating: 0, count: lanes)
        var smallest = [Int32](repeating: 0, count: lanes)

        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let va = unsafe H.load(from: pa.baseAddress!)
                let vb = unsafe H.load(from: pb.baseAddress!)
                sum.withUnsafeMutableBufferPointer {
                    unsafe H.store(H.adding(va, vb), to: $0.baseAddress!)
                }
                product.withUnsafeMutableBufferPointer {
                    unsafe H.store(H.multiplying(va, vb), to: $0.baseAddress!)
                }
                smallest.withUnsafeMutableBufferPointer {
                    unsafe H.store(H.minimum(va, vb), to: $0.baseAddress!)
                }
            }
        }

        #expect(sum == zip(a, b).map(&+))
        #expect(product == zip(a, b).map(&*))
        #expect(smallest == zip(a, b).map(Swift.min))
    }

    @Test("Shifts and bitwise ops match the scalar result")
    func bitwise() {
        typealias H = HighwayUInt32
        let lanes = H.laneCount
        let a = (0..<lanes).map { UInt32(truncatingIfNeeded: $0) &* 2_654_435_761 }

        var shifted = [UInt32](repeating: 0, count: lanes)
        var masked = [UInt32](repeating: 0, count: lanes)

        a.withUnsafeBufferPointer { pa in
            let va = unsafe H.load(from: pa.baseAddress!)
            let mask = H.repeating(0xFF)
            shifted.withUnsafeMutableBufferPointer {
                unsafe H.store(H.shiftedRight(va, by: 8), to: $0.baseAddress!)
            }
            masked.withUnsafeMutableBufferPointer {
                unsafe H.store(H.bitwiseAnd(va, mask), to: $0.baseAddress!)
            }
        }

        #expect(shifted == a.map { $0 >> 8 })
        #expect(masked == a.map { $0 & 0xFF })
    }

    @Test("Comparing produces a mask that selects")
    func compareAndSelect() {
        typealias H = HighwayFloat
        let lanes = H.laneCount
        let a = (0..<lanes).map { Float($0) - 2 }

        var selected = [Float](repeating: 0, count: lanes)
        a.withUnsafeBufferPointer { pa in
            let va = unsafe H.load(from: pa.baseAddress!)
            let zero = H.zero()
            let isNegative = H.lessThan(va, zero)
            selected.withUnsafeMutableBufferPointer {
                unsafe H.store(H.selecting(isNegative, H.negated(va), va), to: $0.baseAddress!)
            }
        }

        #expect(selected == a.map(Swift.abs))
    }

    @Test("Reductions match the scalar result")
    func reductions() {
        typealias H = HighwayInt32
        let lanes = H.laneCount
        let a = (0..<lanes).map { Int32($0) - 3 }

        var sum: Int32 = 0
        var largest: Int32 = 0
        a.withUnsafeBufferPointer { pa in
            let va = unsafe H.load(from: pa.baseAddress!)
            sum = H.sum(va)
            largest = H.largest(va)
        }

        #expect(sum == a.reduce(0, &+))
        #expect(largest == a.max())
    }

    @Test("A partial load only reads the lanes it is asked for")
    func partialLoad() {
        typealias H = HighwayUInt8
        let lanes = H.laneCount
        guard lanes > 3 else { return }
        let input = (0..<lanes).map { UInt8($0 &+ 1) }
        var output = [UInt8](repeating: 0xEE, count: lanes)

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                let v = unsafe H.loadFirst(from: source.baseAddress!, count: 3)
                unsafe H.storeFirst(v, to: destination.baseAddress!, count: 3)
            }
        }

        #expect(Array(output.prefix(3)) == Array(input.prefix(3)))
        #expect(output.dropFirst(3).allSatisfy { $0 == 0xEE })
    }

    @Test("A widening load promotes every lane it reads")
    func wideningLoad() {
        typealias H = HighwayUInt32
        typealias S = HighwayInt64
        let lanes = H.laneCount
        let unsigned = (0..<lanes).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 200) }
        let signed = (0..<S.laneCount).map { Int16(truncatingIfNeeded: $0 &* -3001 &- 1) }

        var widenedUnsigned = [UInt32](repeating: 0, count: lanes)
        var widenedSigned = [Int64](repeating: 0, count: S.laneCount)

        unsigned.withUnsafeBufferPointer { source in
            widenedUnsigned.withUnsafeMutableBufferPointer {
                unsafe H.store(H.loadWidening(from: source.baseAddress!), to: $0.baseAddress!)
            }
        }
        signed.withUnsafeBufferPointer { source in
            widenedSigned.withUnsafeMutableBufferPointer {
                unsafe S.store(S.loadWidening(from: source.baseAddress!), to: $0.baseAddress!)
            }
        }

        #expect(widenedUnsigned == unsigned.map(UInt32.init))
        #expect(widenedSigned == signed.map(Int64.init))
    }

    @Test("A partial widening load zeroes the lanes it is not asked for")
    func partialWideningLoad() {
        typealias H = HighwayDouble
        let lanes = H.laneCount
        guard lanes > 1 else { return }
        let input = (0..<lanes).map { Float($0) + 0.5 }
        var output = [Double](repeating: -1, count: lanes)

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer {
                let v = unsafe H.loadFirstWidening(from: source.baseAddress!, count: 1)
                unsafe H.store(v, to: $0.baseAddress!)
            }
        }

        #expect(output.first == Double(input[0]))
        #expect(output.dropFirst().allSatisfy { $0 == 0 })
    }

    @Test("Interleaved load and store round trip three channels")
    func interleaved() {
        typealias H = HighwayUInt8
        let lanes = H.laneCount
        let input = (0..<(lanes * 3)).map { UInt8($0 & 0xFF) }
        var output = [UInt8](repeating: 0, count: lanes * 3)

        input.withUnsafeBufferPointer { source in
            var v0 = H.zero()
            var v1 = H.zero()
            var v2 = H.zero()
            unsafe H.loadInterleaved3(from: source.baseAddress!, &v0, &v1, &v2)
            output.withUnsafeMutableBufferPointer {
                unsafe H.storeInterleaved3(v0, v1, v2, to: $0.baseAddress!)
            }
        }

        #expect(output == input)
    }

    @Test("A vector survives a span store after a span load")
    func spanLoadStoreRoundTrip() {
        typealias H = HighwayUInt8
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &* 3) })
        var output = ContiguousArray<UInt8>(repeating: 0, count: lanes)

        var destination = output.mutableSpan
        H.store(H.load(from: input.span), to: &destination)

        #expect(output == input)
    }

    @Test("A vector survives an unchecked span store after an unchecked span load")
    func uncheckedSpanLoadStoreRoundTrip() {
        typealias H = HighwayInt32
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { Int32($0) - 2 })
        var output = ContiguousArray<Int32>(repeating: 0, count: lanes)

        var destination = output.mutableSpan
        unsafe H.store(H.load(fromUnchecked: input.span), toUnchecked: &destination)

        #expect(output == input)
    }

    @Test("A vector survives aligned span stores after aligned span loads")
    func alignedSpanLoadStoreRoundTrip() {
        typealias H = HighwayUInt32
        let lanes = H.laneCount
        let byteCount = lanes * MemoryLayout<UInt32>.stride
        let values = (0..<lanes).map { UInt32(truncatingIfNeeded: $0) &* 2_654_435_761 }
        let input =
            unsafe UnsafeMutableRawBufferPointer
            .allocate(byteCount: byteCount, alignment: byteCount)
            .initializeMemory(as: UInt32.self, fromContentsOf: values)
        let checked =
            unsafe UnsafeMutableRawBufferPointer
            .allocate(byteCount: byteCount, alignment: byteCount)
            .initializeMemory(as: UInt32.self, repeating: 0)
        let unchecked =
            unsafe UnsafeMutableRawBufferPointer
            .allocate(byteCount: byteCount, alignment: byteCount)
            .initializeMemory(as: UInt32.self, repeating: 0)
        defer {
            unsafe input.deallocate()
            unsafe checked.deallocate()
            unsafe unchecked.deallocate()
        }

        let source = unsafe input.span
        var checkedDestination = unsafe checked.mutableSpan
        H.storeAligned(H.loadAligned(from: source), to: &checkedDestination)
        var uncheckedDestination = unsafe unchecked.mutableSpan
        unsafe H.storeAligned(
            H.loadAligned(fromUnchecked: source),
            toUnchecked: &uncheckedDestination
        )

        #expect(unsafe Array(checked) == values)
        #expect(unsafe Array(unchecked) == values)
    }

    @Test("A span load reads the start of the span")
    func spanLoadReadsStart() {
        typealias H = HighwayUInt16
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 2)).map { UInt16($0 &* 5) })
        var output = ContiguousArray<UInt16>(repeating: 0, count: lanes)

        var destination = output.mutableSpan
        H.store(H.load(from: input.span.extracting(droppingFirst: lanes)), to: &destination)

        #expect(Array(output) == Array(input.dropFirst(lanes)))
    }

    @Test("A partial span load and store only touch the lanes the span has")
    func partialSpanLoadStore() {
        typealias H = HighwayUInt8
        let lanes = H.laneCount
        guard lanes > 3 else { return }
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        var loaded = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)
        var output = ContiguousArray<UInt8>(repeating: 0xEE, count: lanes)

        let vector = H.loadFirst(from: input.span.extracting(first: 3))
        var whole = loaded.mutableSpan
        H.store(vector, to: &whole)
        output.withUnsafeMutableBufferPointer { buffer in
            let prefix = unsafe UnsafeMutableBufferPointer(rebasing: buffer[0..<3])
            var destination = unsafe prefix.mutableSpan
            H.storeFirst(H.load(from: input.span), to: &destination)
        }

        #expect(Array(loaded.prefix(3)) == Array(input.prefix(3)))
        #expect(loaded.dropFirst(3).allSatisfy { $0 == 0 })
        #expect(Array(output.prefix(3)) == Array(input.prefix(3)))
        #expect(output.dropFirst(3).allSatisfy { $0 == 0xEE })
    }

    @Test("A partial span load and store accept an empty span")
    func emptySpanLoadStore() {
        typealias H = HighwayFloat
        let input = ContiguousArray<Float>()
        var output = ContiguousArray<Float>()

        let vector = H.loadFirst(from: input.span)
        var destination = output.mutableSpan
        H.storeFirst(vector, to: &destination)

        #expect(H.allTrue(H.equalTo(vector, H.zero())))
        #expect(output.isEmpty)
    }

    @Test("A widening span load promotes every lane it reads")
    func spanWideningLoad() {
        typealias H = HighwayUInt32
        typealias S = HighwayInt64
        let unsigned = ContiguousArray(
            (0..<H.laneCount).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 200) }
        )
        let signed = ContiguousArray(
            (0..<S.laneCount).map { Int16(truncatingIfNeeded: $0 &* -3001 &- 1) }
        )
        var widenedUnsigned = ContiguousArray<UInt32>(repeating: 0, count: H.laneCount)
        var widenedSigned = ContiguousArray<Int64>(repeating: 0, count: S.laneCount)

        var unsignedDestination = widenedUnsigned.mutableSpan
        H.store(H.loadWidening(from: unsigned.span), to: &unsignedDestination)
        var signedDestination = widenedSigned.mutableSpan
        unsafe S.store(S.loadWidening(fromUnchecked: signed.span), to: &signedDestination)

        #expect(Array(widenedUnsigned) == unsigned.map(UInt32.init))
        #expect(Array(widenedSigned) == signed.map(Int64.init))
    }

    @Test("A partial widening span load zeroes the lanes the span does not have")
    func partialSpanWideningLoad() {
        typealias H = HighwayDouble
        let lanes = H.laneCount
        guard lanes > 1 else { return }
        let input = ContiguousArray((0..<lanes).map { Float($0) + 0.5 })
        var output = ContiguousArray<Double>(repeating: -1, count: lanes)

        var destination = output.mutableSpan
        H.store(H.loadFirstWidening(from: input.span.extracting(first: 1)), to: &destination)

        #expect(output.first == Double(input[0]))
        #expect(output.dropFirst().allSatisfy { $0 == 0 })
    }

    @Test("Interleaved span load and store round trip three channels")
    func spanInterleaved() {
        typealias H = HighwayUInt8
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 3)).map { UInt8($0 & 0xFF) })
        var output = ContiguousArray<UInt8>(repeating: 0, count: lanes * 3)

        var v0 = H.zero()
        var v1 = H.zero()
        var v2 = H.zero()
        H.loadInterleaved3(from: input.span, &v0, &v1, &v2)
        var destination = output.mutableSpan
        H.storeInterleaved3(v0, v1, v2, to: &destination)

        #expect(output == input)
    }

    @Test("Unchecked interleaved span load and store round trip two channels")
    func uncheckedSpanInterleaved() {
        typealias H = HighwayUInt16
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 2)).map { UInt16($0 &* 7) })
        var output = ContiguousArray<UInt16>(repeating: 0, count: lanes * 2)

        var v0 = H.zero()
        var v1 = H.zero()
        unsafe H.loadInterleaved2(fromUnchecked: input.span, &v0, &v1)
        var destination = output.mutableSpan
        unsafe H.storeInterleaved2(v0, v1, toUnchecked: &destination)

        #expect(output == input)
    }

    @Test("A vector survives appends to an output span after a span load")
    func outputSpanAppendRoundTrip() {
        typealias H = HighwayUInt8
        let lanes = H.laneCount
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &* 3) })

        let output = ContiguousArray<UInt8>(capacity: lanes * 2) { output in
            H.append(H.load(from: input.span), to: &output)
            unsafe H.append(H.load(from: input.span), toUnchecked: &output)
        }

        #expect(output == input + input)
    }

    @Test("An append of a count to an output span only touches that many lanes")
    func partialOutputSpanAppend() {
        typealias H = HighwayUInt8
        let lanes = H.laneCount
        guard lanes > 3 else { return }
        let input = ContiguousArray((0..<lanes).map { UInt8($0 &+ 1) })
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: lanes * 2)
        unsafe buffer.initialize(repeating: 0xEE)
        defer { unsafe buffer.deallocate() }

        var output = unsafe OutputSpan(buffer: buffer, initializedCount: 0)
        H.append(H.load(from: input.span), addingCount: 3, to: &output)
        H.append(H.load(from: input.span), addingCount: 0, to: &output)
        unsafe H.append(H.load(from: input.span), addingCount: lanes, toUnchecked: &output)
        let count = unsafe output.finalize(for: buffer)

        #expect(count == 3 + lanes)
        #expect(unsafe Array(buffer[0..<3]) == Array(input.prefix(3)))
        #expect(unsafe Array(buffer[3..<(3 + lanes)]) == Array(input))
        #expect(unsafe buffer[(3 + lanes)...].allSatisfy { $0 == 0xEE })
    }

    @Test("An append of no lanes accepts an output span without a buffer")
    func emptyOutputSpanAppend() {
        typealias H = HighwayFloat
        var output = OutputSpan<Float>()

        H.append(H.zero(), addingCount: 0, to: &output)
        unsafe H.append(H.zero(), addingCount: 0, toUnchecked: &output)
        let isEmpty = output.isEmpty

        #expect(isEmpty)
    }

    @Test("Aligned appends to an output span continue at aligned addresses")
    func alignedOutputSpanAppend() {
        typealias H = HighwayUInt32
        let lanes = H.laneCount
        let byteCount = lanes * MemoryLayout<UInt32>.stride
        let values = (0..<lanes).map { UInt32(truncatingIfNeeded: $0) &* 2_654_435_761 }
        let input = ContiguousArray(values)
        let buffer =
            unsafe UnsafeMutableRawBufferPointer
            .allocate(byteCount: byteCount * 2, alignment: byteCount)
            .bindMemory(to: UInt32.self)
        defer { unsafe buffer.deallocate() }

        var output = unsafe OutputSpan(buffer: buffer, initializedCount: 0)
        H.appendAligned(H.load(from: input.span), to: &output)
        unsafe H.appendAligned(H.load(from: input.span), toUnchecked: &output)
        let count = unsafe output.finalize(for: buffer)

        #expect(count == lanes * 2)
        #expect(unsafe Array(buffer) == values + values)
    }

    @Test("Interleaved appends to an output span round trip three channels")
    func outputSpanInterleaved() {
        typealias H = HighwayUInt8
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 3)).map { UInt8($0 & 0xFF) })

        var v0 = H.zero()
        var v1 = H.zero()
        var v2 = H.zero()
        H.loadInterleaved3(from: input.span, &v0, &v1, &v2)
        let output = ContiguousArray<UInt8>(capacity: lanes * 3) { output in
            H.appendInterleaved3(v0, v1, v2, to: &output)
        }

        #expect(output == input)
    }

    @Test("Unchecked interleaved appends to an output span round trip two channels")
    func uncheckedOutputSpanInterleaved() {
        typealias H = HighwayUInt16
        let lanes = H.laneCount
        let input = ContiguousArray((0..<(lanes * 2)).map { UInt16($0 &* 7) })

        var v0 = H.zero()
        var v1 = H.zero()
        unsafe H.loadInterleaved2(fromUnchecked: input.span, &v0, &v1)
        let output = ContiguousArray<UInt16>(capacity: lanes * 2) { output in
            unsafe H.appendInterleaved2(v0, v1, toUnchecked: &output)
        }

        #expect(output == input)
    }

    #if os(macOS) || os(Linux) || os(Windows) || os(FreeBSD) || os(OpenBSD)
    @Test("Checked span ops trap on a span that is too short")
    func checkedSpanOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: HighwayUInt8.laneCount - 1)
            _ = HighwayUInt8.load(from: input.span)
        }
        await #expect(processExitsWith: .failure) {
            var output = ContiguousArray<UInt8>(repeating: 0, count: HighwayUInt8.laneCount - 1)
            var destination = output.mutableSpan
            HighwayUInt8.store(HighwayUInt8.zero(), to: &destination)
        }
        await #expect(processExitsWith: .failure) {
            let count = HighwayUInt8.laneCount * 3 - 1
            let input = ContiguousArray<UInt8>(repeating: 0, count: count)
            var v0 = HighwayUInt8.zero()
            var v1 = HighwayUInt8.zero()
            var v2 = HighwayUInt8.zero()
            HighwayUInt8.loadInterleaved3(from: input.span, &v0, &v1, &v2)
        }
        await #expect(processExitsWith: .failure) {
            let count = HighwayUInt8.laneCount * 2 - 1
            var output = ContiguousArray<UInt8>(repeating: 0, count: count)
            var destination = output.mutableSpan
            let zero = HighwayUInt8.zero()
            HighwayUInt8.storeInterleaved2(zero, zero, to: &destination)
        }
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: HighwayUInt32.laneCount - 1)
            _ = HighwayUInt32.loadWidening(from: input.span)
        }
    }

    @Test("Checked aligned span ops trap on a misaligned span")
    func checkedAlignedSpanOpsTrap() async {
        guard HighwayUInt8.laneCount > 1 else { return }
        await #expect(processExitsWith: .failure) {
            let input = ContiguousArray<UInt8>(repeating: 0, count: HighwayUInt8.laneCount * 2)
            _ = HighwayUInt8.loadAligned(from: input.span.extracting(droppingFirst: 1))
        }
        await #expect(processExitsWith: .failure) {
            var output = ContiguousArray<UInt8>(repeating: 0, count: HighwayUInt8.laneCount * 2)
            output.withUnsafeMutableBufferPointer { buffer in
                let shifted = unsafe UnsafeMutableBufferPointer(rebasing: buffer[1...])
                var destination = unsafe shifted.mutableSpan
                HighwayUInt8.storeAligned(HighwayUInt8.zero(), to: &destination)
            }
        }
    }

    @Test("Checked output span ops trap on too little free capacity or a count out of bounds")
    func checkedOutputSpanOpsTrap() async {
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: HighwayUInt8.laneCount - 1) { output in
                HighwayUInt8.append(HighwayUInt8.zero(), to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: HighwayUInt8.laneCount * 2 - 1) { output in
                let zero = HighwayUInt8.zero()
                HighwayUInt8.appendInterleaved2(zero, zero, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: 2) { output in
                HighwayUInt8.append(HighwayUInt8.zero(), addingCount: 3, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: HighwayUInt8.laneCount * 2) { output in
                let count = HighwayUInt8.laneCount + 1
                HighwayUInt8.append(HighwayUInt8.zero(), addingCount: count, to: &output)
            }
        }
        await #expect(processExitsWith: .failure) {
            _ = ContiguousArray<UInt8>(capacity: 1) { output in
                HighwayUInt8.append(HighwayUInt8.zero(), addingCount: -1, to: &output)
            }
        }
    }

    @Test("Checked aligned appends trap on an output span that continues misaligned")
    func checkedAlignedOutputSpanAppendTraps() async {
        guard HighwayUInt8.laneCount > 1 else { return }
        await #expect(processExitsWith: .failure) {
            let lanes = HighwayUInt8.laneCount
            let buffer =
                unsafe UnsafeMutableRawBufferPointer
                .allocate(byteCount: lanes * 2, alignment: lanes)
                .bindMemory(to: UInt8.self)
            unsafe buffer.initialize(repeating: 0)
            var output = unsafe OutputSpan(buffer: buffer, initializedCount: 1)
            HighwayUInt8.appendAligned(HighwayUInt8.zero(), to: &output)
        }
    }
    #endif
}
#endif
