import CoreImage
import XCTest
@testable import LivingFrameCore

final class StickerCatalogTests: XCTestCase {
    func testEmojiStickersRenderFromTheSystemEmojiFont() throws {
        XCTAssertEqual(StickerCategory.allCases, [.doodle, .emoji, .fruit, .logo])

        let emojiStickers = DecorationRenderer.stickerCatalog.filter { $0.category == .emoji }
        XCTAssertEqual(Set(emojiStickers.map(\.id)).count, emojiStickers.count)
        let originalAppleStickerIDs = [
            "sticker-apple-emoji-smile",
            "sticker-apple-emoji-laugh",
            "sticker-apple-emoji-love",
            "sticker-apple-emoji-wink",
            "sticker-apple-emoji-cry",
            "sticker-apple-emoji-think",
            "sticker-apple-emoji-surprise",
            "sticker-apple-emoji-angry"
        ]
        XCTAssertEqual(Array(emojiStickers.prefix(originalAppleStickerIDs.count)).map(\.id), originalAppleStickerIDs)
        XCTAssertGreaterThanOrEqual(emojiStickers.count, 60)
        XCTAssertTrue(emojiStickers.allSatisfy { $0.nativeEmoji != nil && $0.frameCount == 1 })

        let renderer = DecorationRenderer()
        for sticker in emojiStickers {
            let image = try XCTUnwrap(renderer.previewImage(for: sticker.id), sticker.id)
            XCTAssertGreaterThan(image.width, 0, sticker.id)
            XCTAssertGreaterThan(image.height, 0, sticker.id)
        }
    }

    func testGIFBloomLogoStickersAreRegisteredAndLoadAllFrames() {
        XCTAssertEqual(StickerCategory.allCases, [.doodle, .emoji, .fruit, .logo])

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

    func testUnavailableAISchemesAreDeletedFromCatalog() {
        let removedIDs = [
            "sticker-ai-sunglasses",
            "sticker-ai-sunglasses-crayon-2d",
            "sticker-ai-cap-crayon-2d",
            "sticker-ai-sunglasses-crayon-model-3d",
            "sticker-ai-cap-crayon-model-3d"
        ]
        XCTAssertTrue(removedIDs.allSatisfy { DecorationRenderer.stickerDefinition(for: $0) == nil })
        XCTAssertEqual(
            DecorationRenderer.stickerCatalog.filter { $0.category == .aiSticker }.map(\.id),
            [
                "sticker-ai-sunglasses-3d",
                "sticker-ai-sunglasses-crayon-3d",
                "sticker-ai-cap-crayon-3d"
            ]
        )
        XCTAssertEqual(
            DecorationRenderer.availableStickerCatalog.filter { $0.category == .aiSticker }.map(\.id),
            []
        )
    }

    func testCrayon3DStickersLoadFrontAndAlternateViews() throws {
        let renderer = DecorationRenderer()
        for id in ["sticker-ai-sunglasses-crayon-3d", "sticker-ai-cap-crayon-3d"] {
            let sticker = try XCTUnwrap(DecorationRenderer.stickerDefinition(for: id))
            XCTAssertEqual(sticker.renderingMode, .rendered3DViews)
            XCTAssertEqual(sticker.faceViews?.count, 9)
            XCTAssertEqual(renderer.previewFrames(for: id).count, 1)
            for yaw in [CGFloat(0), CGFloat(0.70), CGFloat(1.30)] {
                XCTAssertNotNil(
                    renderer.image(
                        for: id,
                        canvas: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                        faceYaw: yaw
                    ),
                    "3D sticker should render at yaw \(yaw): \(id)"
                )
            }
            for pitch in [CGFloat(-0.45), CGFloat(0.45)] {
                let selection = try XCTUnwrap(
                    DecorationRenderer.faceViewSelection(for: id, yaw: 0.70, pitch: pitch)
                )
                XCTAssertEqual(selection.first.pitchAngle, pitch, accuracy: 0.001)
                XCTAssertEqual(selection.second.pitchAngle, pitch, accuracy: 0.001)
                XCTAssertNotNil(
                    renderer.image(
                        for: id,
                        canvas: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                        faceYaw: 0.70,
                        facePitch: pitch
                    ),
                    "3D sticker should render at pitch \(pitch): \(id)"
                )
            }
        }
    }

    func testCrayonAuthoredViewsUseVisionYawDirection() throws {
        for id in ["sticker-ai-sunglasses-crayon-3d", "sticker-ai-cap-crayon-3d"] {
            let selection = try XCTUnwrap(DecorationRenderer.faceViewSelection(for: id, yaw: 0.70))
            XCTAssertTrue(selection.isMirrored, "Positive Vision yaw should use the mirrored authored view: \(id)")
        }
    }

    func testCrayonProfileViewsUseProjectedSideAnchors() throws {
        let purple = try XCTUnwrap(DecorationRenderer.stickerDefinition(for: "sticker-ai-sunglasses-3d"))
        let purpleThreeQuarter = try XCTUnwrap(purple.faceViews?.first(where: { abs($0.yawAngle - 0.70) < 0.001 && abs($0.pitchAngle) < 0.001 }))
        let purpleProfile = try XCTUnwrap(purple.faceViews?.first(where: { $0.yawAngle > 1.2 && abs($0.pitchAngle) < 0.001 }))
        XCTAssertEqual(try XCTUnwrap(purpleThreeQuarter.anchors.ear?.x), 0.040, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(purpleProfile.anchors.ear?.x), 0.050, accuracy: 0.001)

        let sunglasses = try XCTUnwrap(DecorationRenderer.stickerDefinition(for: "sticker-ai-sunglasses-crayon-3d"))
        let sunglassesProfile = try XCTUnwrap(sunglasses.faceViews?.first(where: { $0.yawAngle > 1.2 && abs($0.pitchAngle) < 0.001 }))
        XCTAssertEqual(sunglassesProfile.anchors.leftEye.x, 0.120, accuracy: 0.001)
        XCTAssertEqual(sunglassesProfile.anchors.rightEye.x, 0.290, accuracy: 0.001)

        let cap = try XCTUnwrap(DecorationRenderer.stickerDefinition(for: "sticker-ai-cap-crayon-3d"))
        let capProfile = try XCTUnwrap(cap.faceViews?.first(where: { $0.yawAngle > 1.2 && abs($0.pitchAngle) < 0.001 }))
        XCTAssertEqual(capProfile.anchors.leftEye.x, 0.280, accuracy: 0.001)
        XCTAssertEqual(capProfile.anchors.rightEye.x, 0.520, accuracy: 0.001)
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
