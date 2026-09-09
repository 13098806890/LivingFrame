import CoreGraphics
import XCTest
@testable import LivingFrameCore

final class ElementFrameGeometryTests: XCTestCase {
    func testFrameUsesOneCoordinateConversionForAnyContentSize() {
        let frame = ElementFrameGeometry.frame(
            contentSize: CGSize(width: 200, height: 100),
            transform: ElementTransform(
                position: CGPoint(x: 500, y: 300),
                scale: 1.5,
                rotation: .pi / 3
            ),
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
            viewportScale: 0.5,
            viewportOffset: CGPoint(x: 20, y: 30)
        )

        XCTAssertEqual(frame, CGRect(x: 195, y: 142.5, width: 150, height: 75))
    }

    func testFrameDoesNotSwapContentSizeWhenRotationIsApplied() {
        let frame = ElementFrameGeometry.frame(
            contentSize: CGSize(width: 320, height: 180),
            transform: ElementTransform(
                position: CGPoint(x: 160, y: 90),
                scale: 1,
                rotation: .pi / 2
            ),
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            viewportScale: 1,
            viewportOffset: .zero
        )

        // The rectangle is kept in content coordinates; SwiftUI applies the
        // same rotation to the border as it does to the rendered element.
        XCTAssertEqual(frame.size, CGSize(width: 320, height: 180))
        XCTAssertEqual(frame.midX, 160)
        XCTAssertEqual(frame.midY, 90)
    }
}
