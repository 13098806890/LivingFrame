import XCTest
@testable import LivingFrameCore

final class SegmentedClipCropTests: XCTestCase {
    func testCropRectDefinesVisibleOrientedDimensions() {
        var clip = SegmentedClip(
            id: "clip",
            name: "clip",
            fps: 1,
            frameCount: 1,
            width: 400,
            height: 300,
            folderURL: URL(fileURLWithPath: "/tmp/clip")
        )
        clip.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.55, height: 0.5333333)

        XCTAssertEqual(clip.renderedWidth, 220)
        XCTAssertEqual(clip.renderedHeight, 160)
        XCTAssertEqual(clip.normalizedCropRect, clip.cropRect)
    }

    func testRawCropRectInvertsClockwiseQuarterTurns() {
        var clip = SegmentedClip(
            id: "clip",
            name: "clip",
            fps: 1,
            frameCount: 1,
            width: 400,
            height: 300,
            folderURL: URL(fileURLWithPath: "/tmp/clip")
        )
        let rotatedCrop = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        clip.cropRect = rotatedCrop

        clip.rotationQuarterTurns = 1
        assertRect(
            clip.rawCropRect,
            equals: CGRect(x: 0.4, y: 0.1, width: 0.4, height: 0.3)
        )

        clip.rotationQuarterTurns = 3
        assertRect(
            clip.rawCropRect,
            equals: CGRect(x: 0.2, y: 0.6, width: 0.4, height: 0.3)
        )
    }

    private func assertRect(
        _ actual: CGRect,
        equals expected: CGRect,
        accuracy: CGFloat = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }
}
