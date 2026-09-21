import CoreGraphics
import XCTest
@testable import LivingFrameCore

final class SegmentationAlgorithmTests: XCTestCase {
    func testTheThreeAlgorithmsHaveStablePublicEntryPoints() {
        XCTAssertEqual(SegmentationAlgorithm.allCases, [.foreground, .visionPerson, .sam2])
        XCTAssertEqual(SegmentationAlgorithm.sam2.title, "SAM2 精准人物")
    }

    func testSAM2PromptUsesAnInteriorLassoPoint() throws {
        let point = try XCTUnwrap(SAM2Segmenter.promptPoint(in: [
            CGPoint(x: 0.2, y: 0.2),
            CGPoint(x: 0.8, y: 0.2),
            CGPoint(x: 0.8, y: 0.8),
            CGPoint(x: 0.2, y: 0.8)
        ]))

        XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
    }

    func testSAM2PromptKeepsForegroundBackgroundAndBoxHints() {
        let prompt = SAM2Prompt(
            foregroundPoints: [CGPoint(x: 0.25, y: 0.30)],
            backgroundPoints: [CGPoint(x: 0.75, y: 0.70)],
            box: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
        )

        XCTAssertTrue(prompt.isUsable)
        guard let foreground = prompt.primaryForegroundPoint else {
            return XCTFail("Expected a usable foreground prompt")
        }
        XCTAssertEqual(foreground.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(foreground.y, 0.30, accuracy: 0.0001)
        XCTAssertEqual(prompt.backgroundPoints.count, 1)
        XCTAssertEqual(prompt.box?.width ?? 0, 0.8, accuracy: 0.0001)
    }

    func testBundledSAM2ModelsLoad() throws {
        _ = try SAM2Segmenter.bundled()
    }

    func testBundledSAM2RunsThePromptAndDecoder() throws {
        let segmenter = try SAM2Segmenter.bundled()
        let image = CIImage(color: CIColor(red: 0.35, green: 0.45, blue: 0.55))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        let result = try XCTUnwrap(segmenter.maskWithScore(
            for: image,
            at: CGPoint(x: 0.5, y: 0.5)
        ))
        XCTAssertEqual(result.mask.extent.width, 96, accuracy: 0.1)
        XCTAssertEqual(result.mask.extent.height, 64, accuracy: 0.1)
    }
}
