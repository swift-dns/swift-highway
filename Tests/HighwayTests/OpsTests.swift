import Testing

@testable import Highway

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
        let a = (0..<lanes).map { UInt32(truncatingIfNeeded: $0 &* 2_654_435_761) }

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
}
