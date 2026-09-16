import XCTest
@testable import LivingFrameCore

final class StickerCatalogTests: XCTestCase {
    func testGIFBloomLogoStickersAreRegisteredAndLoadAllFrames() {
        XCTAssertEqual(StickerCategory.allCases, [.doodle, .logo])

        let logoStickers = DecorationRenderer.stickerCatalog.filter { $0.category == .logo }

        XCTAssertEqual(logoStickers.map(\.id), [
            "sticker-logo-bubble",
            "sticker-logo-hand-lettered",
            "sticker-logo-gradient",
            "sticker-logo-doodle",
            "sticker-logo-crayon"
        ])
        XCTAssertTrue(logoStickers.allSatisfy { $0.name == "logo" })
        XCTAssertTrue(logoStickers.allSatisfy { $0.frameCount == 6 })

        let renderer = DecorationRenderer()
        for sticker in logoStickers {
            let frames = renderer.previewFrames(for: sticker.id)
            XCTAssertEqual(frames.count, 6, sticker.id)
            XCTAssertNotNil(renderer.previewImage(for: sticker.id), sticker.id)
        }
    }
}
