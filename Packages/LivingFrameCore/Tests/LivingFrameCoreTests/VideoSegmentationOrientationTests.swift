import AVFoundation
import XCTest
@testable import LivingFrameCore

final class VideoSegmentationOrientationTests: XCTestCase {
    func testExplicitHalfTurnUsesVideoTransformInsteadOfStillOrientation() {
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1080, ty: 1920)

        XCTAssertFalse(VideoSegmentationPipeline.usesStillOrientation(for: transform))
        XCTAssertEqual(VideoSegmentationPipeline.orientation(from: transform), .down)
    }

    func testIdentityVideoTransformCanUseStillOrientation() {
        XCTAssertTrue(VideoSegmentationPipeline.usesStillOrientation(for: .identity))
    }
}
