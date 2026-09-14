import XCTest
@testable import LivingFrameCore

final class FrameCachePreviewTests: XCTestCase {
    func testPreviewPlaybackUsesOneSharedThumbnailSize() {
        XCTAssertEqual(FrameCache.previewThumbnailMaxPixelSize, 640)
    }
}
