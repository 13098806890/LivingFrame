import XCTest
@testable import LivingFrameCore

final class GIFPhotoLibraryExportTests: XCTestCase {
    func testGIFOutputUsesGIFPhotoResourceType() {
        XCTAssertEqual(GIFPhotoLibraryResourceType.gif.rawValue, "com.compuserve.gif")
    }
}
