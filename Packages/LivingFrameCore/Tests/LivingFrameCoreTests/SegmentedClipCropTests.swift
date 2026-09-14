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
}
