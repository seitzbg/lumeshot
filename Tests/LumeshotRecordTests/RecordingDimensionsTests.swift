import Testing
import CoreGraphics
@testable import LumeshotRecord

@Suite struct RecordingDimensionsTests {
    @Test func displayConvertsPointsToPixelsAtScale() {
        let d = RecordingDimensions.display(pointWidth: 1512, pointHeight: 982, scale: 2)
        #expect(d.width == 3024)
        #expect(d.height == 1964)
        #expect(d.sourceRect == nil)
    }

    @Test func displayRoundsToEvenWhenScaledSizeIsOdd() {
        let d = RecordingDimensions.display(pointWidth: 375.5, pointHeight: 200.5, scale: 1)
        // 375.5 rounds to 376 (already even); 200.5 rounds to 201 (odd) -> 200.
        #expect(d.width == 376)
        #expect(d.height == 200)
    }

    @Test func regionPassesThroughSourceRectAndScalesOutput() {
        let rect = CGRect(x: 10, y: 20, width: 401, height: 301)
        let d = RecordingDimensions.region(rectInPoints: rect, scale: 2)
        #expect(d.width == 802)
        #expect(d.height == 602)
        #expect(d.sourceRect == rect)
    }

    @Test func regionRoundsOddScaledDimensionsToEven() {
        let rect = CGRect(x: 0, y: 0, width: 15, height: 15)
        let d = RecordingDimensions.region(rectInPoints: rect, scale: 1)
        #expect(d.width == 14)
        #expect(d.height == 14)
    }

    @Test func windowHasNoCropAndScalesLikeDisplay() {
        let d = RecordingDimensions.window(pointWidth: 800, pointHeight: 600, scale: 2)
        #expect(d.width == 1600)
        #expect(d.height == 1200)
        #expect(d.sourceRect == nil)
    }

    @Test func degenerateZeroSizeClampsToTheEvenMinimumOfTwo() {
        let d = RecordingDimensions.display(pointWidth: 0, pointHeight: 0, scale: 2)
        #expect(d.width == 2)
        #expect(d.height == 2)
    }

    @Test func equatableComparesAllFields() {
        let a = RecordingDimensions(width: 100, height: 50, sourceRect: CGRect(x: 1, y: 1, width: 2, height: 2))
        let b = RecordingDimensions(width: 100, height: 50, sourceRect: CGRect(x: 1, y: 1, width: 2, height: 2))
        let c = RecordingDimensions(width: 100, height: 50, sourceRect: nil)
        #expect(a == b)
        #expect(a != c)
    }
}
