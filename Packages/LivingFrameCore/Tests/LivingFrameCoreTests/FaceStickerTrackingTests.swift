import CoreGraphics
import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import LivingFrameCore

final class FaceStickerTrackingTests: XCTestCase {
    func testFacePlacementMapsStickerAnchorsToDetectedEyesThroughClipTransform() throws {
        let keyframe = FaceStickerKeyframe(
            frameIndex: 0,
            leftEye: CGPoint(x: 0.25, y: 0.5),
            rightEye: CGPoint(x: 0.75, y: 0.5)
        )
        let clipTransform = ElementTransform(
            position: CGPoint(x: 500, y: 400),
            scale: 0.5,
            rotation: .pi / 2
        )
        let anchors = StickerFaceAnchors(
            leftEye: CGPoint(x: 0.25, y: 0.5),
            rightEye: CGPoint(x: 0.75, y: 0.5)
        )

        let placement = try XCTUnwrap(FaceStickerPlacement.transform(
            for: keyframe,
            frameSize: CGSize(width: 400, height: 200),
            clipTransform: clipTransform,
            stickerSize: CGSize(width: 200, height: 100),
            stickerAnchors: anchors
        ))

        let leftOnCanvas = transformPoint(
            CGPoint(x: 50, y: 50),
            size: CGSize(width: 200, height: 100),
            transform: placement
        )
        let rightOnCanvas = transformPoint(
            CGPoint(x: 150, y: 50),
            size: CGSize(width: 200, height: 100),
            transform: placement
        )
        XCTAssertEqual(leftOnCanvas.x, 500, accuracy: 0.001)
        XCTAssertEqual(leftOnCanvas.y, 350, accuracy: 0.001)
        XCTAssertEqual(rightOnCanvas.x, 500, accuracy: 0.001)
        XCTAssertEqual(rightOnCanvas.y, 450, accuracy: 0.001)
        XCTAssertEqual(placement.rotation, .pi / 2, accuracy: 0.001)

        let resizedPlacement = try XCTUnwrap(FaceStickerPlacement.transform(
            for: keyframe,
            frameSize: CGSize(width: 400, height: 200),
            clipTransform: clipTransform,
            stickerSize: CGSize(width: 200, height: 100),
            stickerAnchors: anchors,
            userOffset: ElementTransform(position: .zero, scale: 1.5)
        ))
        XCTAssertEqual(resizedPlacement.scale, placement.scale * 1.5, accuracy: 0.001)
    }

    func testSideViewPlacementUsesEarWhenAvailableAndFallsBackToEyes() throws {
        let eyeOnlyKeyframe = FaceStickerKeyframe(
            frameIndex: 0,
            leftEye: CGPoint(x: 0.40, y: 0.50),
            rightEye: CGPoint(x: 0.60, y: 0.50),
            yaw: 1.30
        )
        let earKeyframe = FaceStickerKeyframe(
            frameIndex: 0,
            leftEye: eyeOnlyKeyframe.leftEye,
            rightEye: eyeOnlyKeyframe.rightEye,
            yaw: eyeOnlyKeyframe.yaw,
            leftEar: CGPoint(x: 0.90, y: 0.50)
        )
        let anchors = StickerFaceAnchors(
            leftEye: CGPoint(x: 0.12, y: 0.50),
            rightEye: CGPoint(x: 0.29, y: 0.50),
            ear: CGPoint(x: 0.95, y: 0.50)
        )
        let parameters: (FaceStickerKeyframe, StickerFaceAnchors) = (eyeOnlyKeyframe, anchors)
        let eyeOnly = try XCTUnwrap(FaceStickerPlacement.transform(
            for: parameters.0,
            frameSize: CGSize(width: 100, height: 100),
            clipTransform: ElementTransform(position: CGPoint(x: 50, y: 50)),
            stickerSize: CGSize(width: 100, height: 100),
            stickerAnchors: parameters.1
        ))
        let earConstrained = try XCTUnwrap(FaceStickerPlacement.transform(
            for: earKeyframe,
            frameSize: CGSize(width: 100, height: 100),
            clipTransform: ElementTransform(position: CGPoint(x: 50, y: 50)),
            stickerSize: CGSize(width: 100, height: 100),
            stickerAnchors: anchors
        ))

        XCTAssertEqual(earConstrained.scale, 0.537, accuracy: 0.01)
        XCTAssertLessThan(earConstrained.scale, eyeOnly.scale)
        XCTAssertEqual(
            FaceStickerPlacement.transform(
                for: eyeOnlyKeyframe,
                frameSize: CGSize(width: 100, height: 100),
                clipTransform: ElementTransform(position: CGPoint(x: 50, y: 50)),
                stickerSize: CGSize(width: 100, height: 100),
                stickerAnchors: StickerFaceAnchors(
                    leftEye: anchors.leftEye,
                    rightEye: anchors.rightEye
                )
            )?.scale ?? 0,
            eyeOnly.scale,
            accuracy: 0.001
        )
    }

    func testTrackingInterpolatesMissingFrameLandmarks() {
        let tracking = FaceStickerTracking(
            targetClipElementID: UUID(),
            clipID: "clip",
            keyframes: [
                FaceStickerKeyframe(
                    frameIndex: 0,
                    leftEye: CGPoint(x: 0.2, y: 0.4),
                    rightEye: CGPoint(x: 0.4, y: 0.4),
                    yaw: -0.4
                ),
                FaceStickerKeyframe(
                    frameIndex: 4,
                    leftEye: CGPoint(x: 0.6, y: 0.8),
                    rightEye: CGPoint(x: 0.8, y: 0.8),
                    yaw: 0.8
                )
            ]
        )

        let middle = tracking.keyframe(at: 2)
        XCTAssertEqual(middle?.leftEye.x ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(middle?.leftEye.y ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(middle?.rightEye.x ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(middle?.rightEye.y ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(middle?.yaw ?? 0, 0.2, accuracy: 0.001)
    }

    func testScaleSmoothingDampensOneFrameSpikeAndKeepsSustainedMotion() {
        let stableScale: CGFloat = 1
        let dampenedSpike = FaceStickerPlacement.smoothedScale(
            previous: stableScale,
            current: 3,
            next: stableScale
        )
        XCTAssertGreaterThan(dampenedSpike, stableScale)
        XCTAssertLessThan(dampenedSpike, 1.2)

        let sustainedChange = FaceStickerPlacement.smoothedScale(
            previous: 1,
            current: 1.4,
            next: 2
        )
        XCTAssertEqual(sustainedChange, 1.4, accuracy: 0.001)
    }

    func testFaceStickerYawSelectionInterpolatesViewsAndMirrorsAnchors() throws {
        let threeQuarter = try XCTUnwrap(DecorationRenderer.faceViewSelection(
            for: "sticker-ai-sunglasses-3d",
            yaw: 0.70
        ))
        XCTAssertEqual(threeQuarter.first.resourceName, "sunglasses-3d-front")
        XCTAssertEqual(threeQuarter.second.resourceName, "sunglasses-3d-three-quarter")
        XCTAssertEqual(threeQuarter.blend, 1, accuracy: 0.001)

        let mirrored = try XCTUnwrap(DecorationRenderer.faceViewSelection(
            for: "sticker-ai-sunglasses-3d",
            yaw: -0.70
        ))
        XCTAssertTrue(mirrored.isMirrored)
        XCTAssertEqual(mirrored.anchors.leftEye.x, 0.339, accuracy: 0.002)
        XCTAssertEqual(mirrored.anchors.rightEye.x, 0.607, accuracy: 0.002)

        let renderer = DecorationRenderer()
        for stickerID in ["sticker-ai-sunglasses-3d"] {
            let views = try XCTUnwrap(DecorationRenderer.stickerDefinition(for: stickerID)?.faceViews)
            XCTAssertEqual(views.count, 3)
            for view in views {
                let image = renderer.image(
                    for: stickerID,
                    canvas: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                    faceYaw: view.yawAngle
                )
                XCTAssertNotNil(image, "\(stickerID) at yaw \(view.yawAngle)")
            }
        }
    }

    func testOldCompositionElementsDecodeWithoutFaceTrackingData() throws {
        let element = CompositionElement(
            kind: .decoration(decorationID: "sticker-test"),
            name: "test",
            transform: ElementTransform(position: CGPoint(x: 10, y: 20))
        )
        let encoded = try JSONEncoder().encode(element)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "faceStickerTracking")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(CompositionElement.self, from: legacyData)
        XCTAssertNil(decoded.faceStickerTracking)
    }

    func testLegacyFaceStickerKeyframeDecodesWithoutYaw() throws {
        let encoded = try JSONEncoder().encode(FaceStickerKeyframe(
            frameIndex: 3,
            leftEye: CGPoint(x: 0.35, y: 0.6),
            rightEye: CGPoint(x: 0.65, y: 0.6),
            yaw: 0.4
        ))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "yaw")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FaceStickerKeyframe.self, from: legacy)
        XCTAssertEqual(decoded.frameIndex, 3)
        XCTAssertNil(decoded.yaw)
    }

    func testRendererResolvesDifferentTransformsForDifferentSourceFrames() throws {
        let clipID = "face-track-\(UUID().uuidString)"
        let clipElementID = UUID()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(clipID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            FrameCache.shared.removeClip(id: clipID)
            try? FileManager.default.removeItem(at: folder)
        }

        let frame = try XCTUnwrap(makeTransparentFrame(size: CGSize(width: 100, height: 100)))
        for index in 0..<2 {
            let url = folder.appendingPathComponent(String(format: "%05d.png", index))
            XCTAssertTrue(writePNG(frame, to: url))
        }

        let clip = SegmentedClip(
            id: clipID,
            name: "face clip",
            fps: 1,
            frameCount: 2,
            width: 100,
            height: 100,
            folderURL: folder
        )
        FrameCache.shared.registerInMemory(clip)
        let clipElement = CompositionElement(
            id: clipElementID,
            kind: .clip(clipID: clipID),
            name: clip.name,
            transform: ElementTransform(position: CGPoint(x: 500, y: 500)),
            zIndex: 0,
            startTime: 0,
            endTime: 2,
            sourceEndTime: 2
        )
        let sticker = CompositionElement(
            kind: .decoration(decorationID: "sticker-ai-sunglasses-3d"),
            name: "墨镜",
            transform: ElementTransform(position: .zero),
            zIndex: 1,
            startTime: 0,
            endTime: 2,
            sourceEndTime: 1,
            faceStickerTracking: FaceStickerTracking(
                targetClipElementID: clipElementID,
                clipID: clipID,
                keyframes: [
                    FaceStickerKeyframe(
                        frameIndex: 0,
                        leftEye: CGPoint(x: 0.25, y: 0.5),
                        rightEye: CGPoint(x: 0.75, y: 0.5),
                        yaw: 0
                    ),
                    FaceStickerKeyframe(
                        frameIndex: 1,
                        leftEye: CGPoint(x: 0.45, y: 0.55),
                        rightEye: CGPoint(x: 0.85, y: 0.75),
                        yaw: 0.68
                    )
                ]
            )
        )
        let composition = Composition(
            name: "tracked sunglasses",
            canvas: CanvasSpec(width: 1024, height: 1024),
            duration: 2,
            fps: 1,
            elements: [clipElement, sticker],
            background: .clear
        )
        let renderer = CompositionRenderer()

        let first = renderer.resolvedTransform(for: sticker, in: composition, at: 0)
        let second = renderer.resolvedTransform(for: sticker, in: composition, at: 1)

        XCTAssertNotEqual(second.position.x, first.position.x)
        XCTAssertNotEqual(second.scale, first.scale)
        XCTAssertGreaterThan(second.rotation, 0.4)

        for time: TimeInterval in [0, 1] {
            let rendered = try XCTUnwrap(renderer.render(composition, at: time))
            XCTAssertNotNil(
                AlphaSubjectBounds.visiblePixelBounds(in: rendered),
                "2D tracked sunglasses should render visible pixels at time \(time)"
            )
        }

        var hiddenClipElement = clipElement
        hiddenClipElement.endTime = 0.5
        var hiddenTargetComposition = composition
        hiddenTargetComposition.elements = [hiddenClipElement, sticker]
        let hiddenTargetTransform = renderer.resolvedTransform(
            for: sticker,
            in: hiddenTargetComposition,
            at: 1
        )
        XCTAssertEqual(hiddenTargetTransform, sticker.transform)
    }

    func testRendererUsesNeighborFramesToDampen3DStickerScaleSpike() throws {
        let clipID = "face-scale-(UUID().uuidString)"
        let clipElementID = UUID()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(clipID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            FrameCache.shared.removeClip(id: clipID)
            try? FileManager.default.removeItem(at: folder)
        }

        let frame = try XCTUnwrap(makeTransparentFrame(size: CGSize(width: 100, height: 100)))
        for index in 0..<3 {
            let url = folder.appendingPathComponent(String(format: "%05d.png", index))
            XCTAssertTrue(writePNG(frame, to: url))
        }

        let clip = SegmentedClip(
            id: clipID,
            name: "scale spike clip",
            fps: 1,
            frameCount: 3,
            width: 100,
            height: 100,
            folderURL: folder
        )
        FrameCache.shared.registerInMemory(clip)
        let clipElement = CompositionElement(
            id: clipElementID,
            kind: .clip(clipID: clipID),
            name: clip.name,
            transform: ElementTransform(position: CGPoint(x: 500, y: 500)),
            zIndex: 0,
            startTime: 0,
            endTime: 3,
            sourceEndTime: 3
        )
        let sticker = CompositionElement(
            kind: .decoration(decorationID: "sticker-ai-sunglasses-3d"),
            name: "紫晶墨镜",
            transform: ElementTransform(position: .zero),
            zIndex: 1,
            startTime: 0,
            endTime: 3,
            sourceEndTime: 1,
            faceStickerTracking: FaceStickerTracking(
                targetClipElementID: clipElementID,
                clipID: clipID,
                keyframes: [
                    FaceStickerKeyframe(
                        frameIndex: 0,
                        leftEye: CGPoint(x: 0.30, y: 0.5),
                        rightEye: CGPoint(x: 0.70, y: 0.5),
                        yaw: 0
                    ),
                    FaceStickerKeyframe(
                        frameIndex: 1,
                        leftEye: CGPoint(x: 0.10, y: 0.5),
                        rightEye: CGPoint(x: 0.90, y: 0.5),
                        yaw: 0
                    ),
                    FaceStickerKeyframe(
                        frameIndex: 2,
                        leftEye: CGPoint(x: 0.30, y: 0.5),
                        rightEye: CGPoint(x: 0.70, y: 0.5),
                        yaw: 0
                    )
                ]
            )
        )
        let composition = Composition(
            name: "smoothed face scale",
            canvas: CanvasSpec(width: 1024, height: 1024),
            duration: 3,
            fps: 1,
            elements: [clipElement, sticker],
            background: .clear
        )
        let renderer = CompositionRenderer()

        let first = renderer.resolvedTransform(for: sticker, in: composition, at: 0)
        let spike = renderer.resolvedTransform(for: sticker, in: composition, at: 1)
        let last = renderer.resolvedTransform(for: sticker, in: composition, at: 2)

        XCTAssertLessThan(spike.scale, first.scale * 1.25)
        XCTAssertLessThan(last.scale, first.scale * 1.25)
        XCTAssertEqual(first.scale, last.scale, accuracy: 0.001)
    }

    private func transformPoint(_ point: CGPoint, size: CGSize, transform: ElementTransform) -> CGPoint {
        let x = (point.x - size.width / 2) * transform.scale
        let y = (point.y - size.height / 2) * transform.scale
        let cosine = cos(transform.rotation)
        let sine = sin(transform.rotation)
        return CGPoint(
            x: transform.position.x + x * cosine - y * sine,
            y: transform.position.y + x * sine + y * cosine
        )
    }

    private func makeTransparentFrame(size: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
