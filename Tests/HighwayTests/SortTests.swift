#if !$Embedded && !os(WASI)
import Highway
import Testing

@Suite("Sort")
struct SortTests {
    static let counts = [0, 1, 2, 17, 1_000, 4_097]

    private func shuffled<Key: HighwaySortable & Comparable & FixedWidthInteger>(
        _ type: Key.Type,
        count: Int
    ) -> [Key] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in Key.random(in: Key.min...Key.max, using: &generator) }
    }

    @Test("Sorts integers ascending and descending", arguments: counts)
    func sortsIntegers(count: Int) {
        var keys = shuffled(Int32.self, count: count)
        let expected = keys.sorted()

        Highway.sort(&keys)
        #expect(keys == expected)

        Highway.sort(&keys, order: .descending)
        #expect(keys == expected.reversed())
    }

    @Test("Sorts every supported key type")
    func sortsEveryKeyType() {
        func check<Key: HighwaySortable & Comparable & FixedWidthInteger>(_ type: Key.Type) {
            var keys = shuffled(type, count: 257)
            let expected = keys.sorted()
            Highway.sort(&keys)
            #expect(keys == expected, "\(type) did not sort ascending")
        }

        check(UInt16.self)
        check(UInt32.self)
        check(UInt64.self)
        check(Int16.self)
        check(Int32.self)
        check(Int64.self)
    }

    @Test("Sorts floating point keys")
    func sortsFloats() {
        var floats = (0..<513).map { _ in Float.random(in: -1_000...1_000) }
        let expectedFloats = floats.sorted()
        Highway.sort(&floats)
        #expect(floats == expectedFloats)

        var doubles = (0..<513).map { _ in Double.random(in: -1_000...1_000) }
        let expectedDoubles = doubles.sorted()
        Highway.sort(&doubles)
        #expect(doubles == expectedDoubles)
    }

    @Test("A partial sort places the requested prefix")
    func partialSorts() {
        var keys = shuffled(Int32.self, count: 2_000)
        let expected = Array(keys.sorted().prefix(20))

        Highway.partialSort(&keys, keeping: 20)
        #expect(Array(keys.prefix(20)) == expected)
    }

    @Test("Selecting places the element the index would hold")
    func selects() {
        var keys = shuffled(Int32.self, count: 2_000)
        let expected = keys.sorted()[500]

        Highway.select(&keys, at: 500)
        #expect(keys[500] == expected)
        #expect(keys.prefix(500).allSatisfy { $0 <= expected })
    }

    @Test("Sorting is stable against an already sorted input")
    func sortsSortedInput() {
        var keys = (0..<1_000).map { Int64($0) }
        let expected = keys
        Highway.sort(&keys)
        #expect(keys == expected)
    }

    @Test("Sorts a mutable span ascending and descending", arguments: counts)
    func sortsMutableSpan(count: Int) {
        var keys = ContiguousArray(shuffled(Int32.self, count: count))
        let expected = keys.sorted()

        var ascending = keys.mutableSpan
        Highway.sort(&ascending)
        #expect(Array(keys) == expected)

        var descending = keys.mutableSpan
        Highway.sort(&descending, order: .descending)
        #expect(Array(keys) == expected.reversed())
    }

    @Test("A partial sort of a mutable span places the requested prefix")
    func partialSortsMutableSpan() {
        var keys = ContiguousArray(shuffled(Int32.self, count: 2_000))
        let expected = Array(keys.sorted().prefix(20))

        var span = keys.mutableSpan
        Highway.partialSort(&span, keeping: 20)
        #expect(Array(keys.prefix(20)) == expected)
    }

    @Test("Selecting in a mutable span places the element the index would hold")
    func selectsInMutableSpan() {
        var keys = ContiguousArray(shuffled(Int32.self, count: 2_000))
        let expected = keys.sorted()[500]

        var span = keys.mutableSpan
        Highway.select(&span, at: 500)
        #expect(keys[500] == expected)
        #expect(keys.prefix(500).allSatisfy { $0 <= expected })
    }

    @Test("Unchecked partial sort and select of a mutable span match the checked ones")
    func uncheckedSpanSorting() {
        var partial = ContiguousArray(shuffled(Int64.self, count: 1_000))
        let expectedPrefix = Array(partial.sorted().prefix(10))
        var selected = ContiguousArray(shuffled(UInt16.self, count: 1_000))
        let expectedElement = selected.sorted()[100]

        var partialSpan = partial.mutableSpan
        unsafe Highway.partialSort(&partialSpan, keepingUnchecked: 10)
        var selectedSpan = selected.mutableSpan
        unsafe Highway.select(&selectedSpan, atUnchecked: 100)

        #expect(Array(partial.prefix(10)) == expectedPrefix)
        #expect(selected[100] == expectedElement)
    }

    #if os(macOS) || os(Linux) || os(Windows) || os(FreeBSD) || os(OpenBSD)
    @Test("Sorting a mutable span traps on a count or index past its end")
    func spanSortingTrapsOutOfBounds() async {
        await #expect(processExitsWith: .failure) {
            var keys = ContiguousArray<Int32>(repeating: 0, count: 4)
            var span = keys.mutableSpan
            Highway.partialSort(&span, keeping: 5)
        }
        await #expect(processExitsWith: .failure) {
            var keys = ContiguousArray<Int32>(repeating: 0, count: 4)
            var span = keys.mutableSpan
            Highway.select(&span, at: 4)
        }
    }
    #endif
}
#endif
