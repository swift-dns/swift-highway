#if !$Embedded && !os(WASI)
import Highway
import Testing

@Suite("Target")
struct TargetTests {
    @Test("Reports the target it was compiled for")
    func reportsTarget() {
        #expect(!Highway.targetName.isEmpty)
    }

    @Test("Every element type has lanes unless the target is emulated")
    func laneCounts() {
        guard !Highway.isEmulated else { return }
        #expect(HighwayUInt8.laneCount > 0)
        #expect(HighwayUInt16.laneCount > 0)
        #expect(HighwayUInt32.laneCount > 0)
        #expect(HighwayUInt64.laneCount > 0)
        #expect(HighwayInt8.laneCount > 0)
        #expect(HighwayInt16.laneCount > 0)
        #expect(HighwayInt32.laneCount > 0)
        #expect(HighwayInt64.laneCount > 0)
        #expect(HighwayFloat.laneCount > 0)
        #expect(HighwayDouble.laneCount > 0)
    }

    @Test("A wider element type has proportionally fewer lanes")
    func laneCountsScaleWithWidth() {
        guard !Highway.isEmulated else { return }
        #expect(HighwayUInt8.laneCount == HighwayUInt16.laneCount * 2)
        #expect(HighwayUInt16.laneCount == HighwayUInt32.laneCount * 2)
        #expect(HighwayUInt32.laneCount == HighwayUInt64.laneCount * 2)
    }
}
#endif
