import XCTest
@testable import LivingFrameCore

final class ClipExportStateTests: XCTestCase {
    func testExportStateIsInvalidatedWhenClipPresentationChanges() {
        var state = ClipExportState()
        state.markExported(for: 0, cropKey: "full", resolution: .p720)

        XCTAssertTrue(state.isCurrent(for: 0, cropKey: "full", resolution: .p720))
        XCTAssertFalse(state.isCurrent(for: 1, cropKey: "full", resolution: .p720))
        XCTAssertFalse(state.isCurrent(for: 0, cropKey: "cropped", resolution: .p720))
        XCTAssertFalse(state.isCurrent(for: 0, cropKey: "full", resolution: .original))
    }
}
