import Testing
import Foundation
@testable import Ghostty

struct SplitGeometryTests {
    let extent: CGFloat = 1000
    let minSize: CGFloat = 24

    /// Dragging past the window edge (gesture location well outside
    /// `[0, extent]`) must never collapse a pane below `minSize`. Regression
    /// guard for the `+`-junction crash, where an out-of-bounds drag pinned a
    /// pane to a sub-row size and overflowed terminal reflow.
    @Test func clampsOutOfBoundsBelowMinimum() {
        for loc in [-10000, -1, 0, 5, 23] as [CGFloat] {
            let r = SplitGeometry.clampedRatio(loc, extent: extent, minSize: minSize)
            #expect(r >= minSize / extent)
            #expect(r <= 1 - minSize / extent)
            #expect(r > 0 && r < 1)
        }
    }

    @Test func clampsOutOfBoundsAboveMaximum() {
        for loc in [10000, 1001, 1000, 995, 977] as [CGFloat] {
            let r = SplitGeometry.clampedRatio(loc, extent: extent, minSize: minSize)
            #expect(r >= minSize / extent)
            #expect(r <= 1 - minSize / extent)
            #expect(r > 0 && r < 1)
        }
    }

    @Test func centerMapsToMidpoint() {
        let r = SplitGeometry.clampedRatio(500, extent: extent, minSize: minSize)
        #expect(abs(r - 0.5) < 0.0001)
    }

    /// Extents too small to honor `minSize` on both sides fall back to center
    /// rather than producing a negative or out-of-range ratio.
    @Test func degenerateExtentFallsBackToCenter() {
        #expect(SplitGeometry.clampedRatio(10, extent: minSize, minSize: minSize) == 0.5)
        #expect(SplitGeometry.clampedRatio(10, extent: 0, minSize: minSize) == 0.5)
        #expect(SplitGeometry.clampedRatio(-5, extent: 40, minSize: minSize) == 0.5)
    }
}
