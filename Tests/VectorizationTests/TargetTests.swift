import Testing
import Vectorization

@Suite("Target")
struct TargetTests {
    @Test("Reports the target it was compiled for")
    func reportsTarget() {
        #expect(!SIMDTarget.targetName.isEmpty)
    }

    @Test("Every element type has lanes unless the target is emulated")
    func laneCounts() {
        guard !SIMDTarget.isEmulated else { return }
        #expect(SIMDUInt8.laneCount > 0)
        #expect(SIMDUInt16.laneCount > 0)
        #expect(SIMDUInt32.laneCount > 0)
        #expect(SIMDUInt64.laneCount > 0)
        #expect(SIMDInt8.laneCount > 0)
        #expect(SIMDInt16.laneCount > 0)
        #expect(SIMDInt32.laneCount > 0)
        #expect(SIMDInt64.laneCount > 0)
        #expect(SIMDFloat.laneCount > 0)
        #expect(SIMDDouble.laneCount > 0)
    }

    @Test("A wider element type has proportionally fewer lanes")
    func laneCountsScaleWithWidth() {
        guard !SIMDTarget.isEmulated else { return }
        #expect(SIMDUInt8.laneCount == SIMDUInt16.laneCount * 2)
        #expect(SIMDUInt16.laneCount == SIMDUInt32.laneCount * 2)
        #expect(SIMDUInt32.laneCount == SIMDUInt64.laneCount * 2)
    }
}
