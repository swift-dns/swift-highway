import Testing
import Vectorization

func maskHighNibbles(
    _ input: UnsafePointer<UInt8>,
    _ count: Int,
    _ output: UnsafeMutablePointer<UInt8>
) {
    typealias H = SIMDUInt8

    let lanes = H.laneCount
    let mask = H.repeating(0x0F)
    var index = 0

    while count - index >= lanes {
        let loaded = unsafe H.load(from: input + index)
        unsafe H.store(H.bitwiseAnd(H.shiftedRight(loaded, by: 2), mask), to: output + index)
        index += lanes
    }
}

func sum<E: SIMDIntegerElement>(
    _ type: E.Type,
    _ input: UnsafePointer<E.Lane>,
    _ count: Int
) -> E.Vector {
    var total = E.zero()
    var index = 0
    while count - index >= E.laneCount {
        total = unsafe E.adding(total, E.load(from: input + index))
        index += E.laneCount
    }
    return total
}

func sum<E: SIMDIntegerElement>(_ type: E.Type, _ input: Span<E.Lane>) -> E.Vector {
    var total = E.zero()
    var rest = input
    while rest.count >= E.laneCount {
        total = E.adding(total, E.load(from: rest))
        rest = rest.extracting(droppingFirst: E.laneCount)
    }
    return E.adding(total, E.loadFirst(from: rest))
}

@Suite("Kernels")
struct KernelTests {
    @Test("A hand-written kernel masks high nibbles")
    func kernelExample() {
        let lanes = SIMDUInt8.laneCount
        let input = (0..<(lanes * 2)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        var output = [UInt8](repeating: 0, count: lanes * 2)

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                unsafe maskHighNibbles(source.baseAddress!, input.count, destination.baseAddress!)
            }
        }

        #expect(output == input.map { ($0 >> 2) & 0x0F })
    }

    @Test("A generic kernel sums lanes")
    func genericExample() {
        let lanes = SIMDInt32.laneCount
        let input = (0..<(lanes * 3)).map { Int32($0) }

        let total = input.withUnsafeBufferPointer { source in
            unsafe SIMDInt32.sum(sum(SIMDInt32.self, source.baseAddress!, input.count))
        }

        #expect(total == input.reduce(0, &+))
    }

    @Test("A generic span kernel sums lanes, including a partial last vector")
    func genericSpanExample() {
        let lanes = SIMDInt32.laneCount
        let input = ContiguousArray((0..<(lanes * 3 + 1)).map { Int32($0) })

        let total = SIMDInt32.sum(sum(SIMDInt32.self, input.span))

        #expect(total == input.reduce(0, &+))
    }
}
