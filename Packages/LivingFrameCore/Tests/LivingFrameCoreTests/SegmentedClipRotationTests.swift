import XCTest
@testable import LivingFrameCore

final class SegmentedClipRotationTests: XCTestCase {
    func testFourClockwiseQuarterTurnsKeepContinuousAnimationValue() {
        var clip = SegmentedClip(
            id: "clip",
            name: "clip",
            fps: 1,
            frameCount: 1,
            width: 100,
            height: 100,
            folderURL: URL(fileURLWithPath: "/tmp/clip")
        )

        for _ in 0..<4 {
            clip.rotateClockwiseQuarterTurn()
        }

        XCTAssertEqual(clip.rotationQuarterTurns, 4)
        XCTAssertEqual(clip.normalizedRotationQuarterTurns, 0)
    }

    func testQuarterTurnSwapsOrientedDimensionsWithoutChangingSourceDimensions() {
        var clip = SegmentedClip(
            id: "clip",
            name: "clip",
            fps: 1,
            frameCount: 1,
            width: 800,
            height: 400,
            folderURL: URL(fileURLWithPath: "/tmp/clip")
        )

        clip.rotateClockwiseQuarterTurn()

        XCTAssertEqual(clip.width, 800)
        XCTAssertEqual(clip.height, 400)
        XCTAssertEqual(clip.orientedWidth, 400)
        XCTAssertEqual(clip.orientedHeight, 800)
    }
}
