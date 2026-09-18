import CoreImage
import XCTest
@testable import LivingFrameCore

final class StickerCatalogTests: XCTestCase {
    func testEmojiStickersAreRegisteredInTheExpressionCategory() {
        XCTAssertEqual(StickerCategory.allCases, [.doodle, .expression, .fruit, .aiSticker, .logo])

        let emojiStickers = DecorationRenderer.stickerCatalog.filter { $0.category == .expression }

        XCTAssertEqual(emojiStickers.map(\.id), [
            "sticker-emoji-smile",
            "sticker-emoji-laugh",
            "sticker-emoji-love",
            "sticker-emoji-wink",
            "sticker-emoji-cry",
            "sticker-emoji-think",
            "sticker-emoji-surprise",
            "sticker-emoji-angry"
        ])
    }

    func testGIFBloomLogoStickersAreRegisteredAndLoadAllFrames() {
        XCTAssertEqual(StickerCategory.allCases, [.doodle, .expression, .fruit, .aiSticker, .logo])

        let logoStickers = DecorationRenderer.stickerCatalog.filter { $0.category == .logo }

        XCTAssertEqual(logoStickers.map(\.id), [
            "sticker-logo-hand-lettered",
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

    func testRemovedLogoStickersAreNotRegisteredOrWatermarked() {
        let removedIDs: Set<String> = [
            "sticker-logo-bubble",
            "sticker-logo-gradient"
        ]
        let availableLogoIDs = DecorationRenderer.availableStickerCatalog
            .filter { $0.category == .logo }.map(\.id)

        XCTAssertEqual(availableLogoIDs, [
            "sticker-logo-hand-lettered",
            "sticker-logo-doodle",
            "sticker-logo-crayon"
        ])
        XCTAssertTrue(removedIDs.allSatisfy { id in
            !DecorationRenderer.stickerCatalog.contains { $0.id == id }
        })

        for _ in 0..<100 {
            let watermarkID = DecorationRenderer.randomLogoWatermark()?.decorationID
            XCTAssertNotNil(watermarkID)
            XCTAssertTrue(watermarkID.map(availableLogoIDs.contains) == true)
        }
    }

    func testFruitStickersAreRegisteredAndLoadAllFrames() {
        let fruitStickers = DecorationRenderer.stickerCatalog.filter { $0.category == .fruit }

        XCTAssertEqual(fruitStickers.map(\.id), [
            "sticker-fruit-apple",
            "sticker-fruit-banana",
            "sticker-fruit-orange",
            "sticker-fruit-strawberry",
            "sticker-fruit-grapes",
            "sticker-fruit-watermelon",
            "sticker-fruit-peaches",
            "sticker-fruit-pineapple",
            "sticker-fruit-lemon",
            "sticker-fruit-pear",
            "sticker-fruit-mango",
            "sticker-fruit-kiwi",
            "sticker-fruit-cherries",
            "sticker-fruit-avocado",
            "sticker-fruit-blueberries",
            "sticker-fruit-plum"
        ])
        XCTAssertTrue(fruitStickers.allSatisfy { $0.frameCount == 5 && $0.frameDuration == 0.2 })

        let renderer = DecorationRenderer()
        for sticker in fruitStickers {
            XCTAssertEqual(renderer.previewFrames(for: sticker.id).count, 5, sticker.id)
            XCTAssertNotNil(renderer.previewImage(for: sticker.id), sticker.id)
        }
    }

    func testSunglassesStickerIsRegisteredWithFaceAnchorsAndLoads() {
        let sticker = DecorationRenderer.stickerDefinition(for: "sticker-ai-sunglasses")
        XCTAssertEqual(sticker?.category, .aiSticker)
        XCTAssertEqual(sticker?.renderingMode, .multiView2D)
        XCTAssertEqual(sticker?.resourceName, "sunglasses")
        XCTAssertEqual(sticker?.resourceExtension, "png")
        XCTAssertEqual(sticker?.frameCount, 1)
        XCTAssertEqual(sticker?.faceAnchors, StickerFaceAnchors(
            leftEye: CGPoint(x: 0.297, y: 0.510),
            rightEye: CGPoint(x: 0.703, y: 0.510)
        ))

        let renderer = DecorationRenderer()
        XCTAssertEqual(renderer.previewFrames(for: "sticker-ai-sunglasses").count, 1)
        XCTAssertNotNil(renderer.previewImage(for: "sticker-ai-sunglasses"))
    }

    func test2DAnd3DSunglassesShareCategoryAndKeepSeparateRenderingModes() throws {
        let twoD = try XCTUnwrap(DecorationRenderer.stickerDefinition(for: "sticker-ai-sunglasses"))
        let threeD = try XCTUnwrap(DecorationRenderer.stickerDefinition(for: "sticker-ai-sunglasses-3d"))

        XCTAssertEqual(twoD.category, .aiSticker)
        XCTAssertEqual(twoD.renderingMode, .multiView2D)
        XCTAssertEqual(threeD.category, .aiSticker)
        XCTAssertEqual(threeD.renderingMode, .rendered3DViews)
        XCTAssertTrue(twoD.category.requiresPro)
        XCTAssertTrue(threeD.category.requiresPro)
        XCTAssertEqual(
            DecorationRenderer.stickerCatalog.filter { $0.category == .aiSticker }.map(\.id),
            ["sticker-ai-sunglasses", "sticker-ai-sunglasses-3d"]
        )

        let selection = try XCTUnwrap(DecorationRenderer.faceViewSelection(for: twoD.id, yaw: 0.34))
        XCTAssertEqual(selection.anchors(for: .multiView2D), selection.nearestView.anchors)
        XCTAssertNotEqual(selection.anchors(for: .rendered3DViews), selection.nearestView.anchors)
    }

    func test2DStickerSelectsAndDisplaysEachAuthoredAngle() throws {
        let renderer = DecorationRenderer()
        var visibleBounds: [CGRect] = []

        for yaw: CGFloat in [0, 0.68, 1.28] {
            let ciImage = try XCTUnwrap(renderer.image(
                for: "sticker-ai-sunglasses",
                canvas: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                faceYaw: yaw
            ), "2D render at yaw \(yaw)")
            let cgImage = try XCTUnwrap(
                CIContext().createCGImage(ciImage, from: ciImage.extent),
                "2D image decode at yaw \(yaw)"
            )
            visibleBounds.append(try XCTUnwrap(
                AlphaSubjectBounds.visiblePixelBounds(in: cgImage),
                "2D sticker must contain visible artwork at yaw \(yaw)"
            ))
        }

        XCTAssertEqual(visibleBounds.count, 3)
        XCTAssertNotEqual(visibleBounds[0], visibleBounds[1], "Three-quarter yaw should select its authored 2D view")
        XCTAssertNotEqual(visibleBounds[1], visibleBounds[2], "Profile yaw should select its authored 2D view")
    }

    func testStickerSelectionBoundsExcludeTransparentPaddingAndCoverEveryFrame() throws {
        let renderer = DecorationRenderer()
        let stickerID = "sticker-fruit-apple"
        let frames = renderer.previewFrames(for: stickerID)
        let bounds = try XCTUnwrap(renderer.selectionBounds(for: stickerID))

        XCTAssertFalse(frames.isEmpty)
        XCTAssertLessThan(bounds.width, CGFloat(frames[0].width))
        XCTAssertLessThan(bounds.height, CGFloat(frames[0].height))

        for frame in frames {
            let pixels = try XCTUnwrap(AlphaSubjectBounds.visiblePixelBounds(in: frame))
            let frameBounds = CGRect(
                x: pixels.minX,
                y: CGFloat(frame.height) - pixels.maxY,
                width: pixels.width,
                height: pixels.height
            )
            XCTAssertTrue(bounds.contains(frameBounds), "Selection bounds must cover every animation frame")
        }
    }

    func testFaceStickerSelectionBoundsCoverAlternateViewsWithoutSquarePadding() throws {
        let renderer = DecorationRenderer()
        let stickerID = "sticker-ai-sunglasses-3d"
        let frontView = try XCTUnwrap(renderer.previewImage(for: stickerID))
        let frontPixels = try XCTUnwrap(AlphaSubjectBounds.visiblePixelBounds(in: frontView))
        let bounds = try XCTUnwrap(renderer.selectionBounds(for: stickerID))
        let frontBounds = CGRect(
            x: frontPixels.minX,
            y: CGFloat(frontView.height) - frontPixels.maxY,
            width: frontPixels.width,
            height: frontPixels.height
        )

        XCTAssertGreaterThan(bounds.width, bounds.height)
        XCTAssertLessThan(bounds.width, CGFloat(frontView.width))
        XCTAssertLessThan(bounds.height, CGFloat(frontView.height) / 2)
        XCTAssertLessThan(bounds.minX, frontBounds.minX, "Selection bounds must include the side profile view")
    }
}
