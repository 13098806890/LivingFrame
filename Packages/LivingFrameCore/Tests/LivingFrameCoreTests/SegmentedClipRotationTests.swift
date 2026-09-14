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

    func testContinuousRotationDegreesProgressFrom270To360() {
        var clip = SegmentedClip(
            id: "clip",
            name: "clip",
            fps: 1,
            frameCount: 1,
            width: 100,
            height: 100,
            folderURL: URL(fileURLWithPath: "/tmp/clip")
        )
        clip.rotationQuarterTurns = 3
        XCTAssertEqual(clip.continuousRotationDegrees, 270)

        clip.rotateClockwiseQuarterTurn()

        XCTAssertEqual(clip.continuousRotationDegrees, 360)
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

    func testCounterclockwiseQuarterTurnPreservesCropInSourceCoordinates() {
        var clip = SegmentedClip(
            id: "clip",
            name: "clip",
            fps: 1,
            frameCount: 1,
            width: 800,
            height: 400,
            folderURL: URL(fileURLWithPath: "/tmp/clip"),
            cropRect: CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.4)
        )

        clip.rotateCounterclockwiseQuarterTurn()

        XCTAssertEqual(clip.rotationQuarterTurns, -1)
        XCTAssertEqual(clip.normalizedRotationQuarterTurns, 3)
        XCTAssertEqual(clip.orientedWidth, 400)
        XCTAssertEqual(clip.orientedHeight, 800)
        XCTAssertEqual(clip.rawCropRect.minX, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(clip.rawCropRect.minY, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(clip.rawCropRect.width, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(clip.rawCropRect.height, 0.4, accuracy: 0.000_001)
    }
}
