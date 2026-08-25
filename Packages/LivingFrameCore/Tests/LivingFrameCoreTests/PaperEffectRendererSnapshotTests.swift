import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LivingFrameCore

final class PaperEffectRendererSnapshotTests: XCTestCase {
    func testRemovedWidthValuesRenderAsNarrow() throws {
        let size = CGSize(width: 640, height: 400)
        func edge(_ width: CanvasEdgeWidth) -> CGImage? {
            BackgroundMaskRenderer.edgeImage(
                size: size,
                settings: BackgroundElementSettings(
                    edgeStyle: .tornLayered,
                    edgeWidth: width,
                    splitCount: .four,
                    dividerAngle: 90,
                    selectedPartition: 0
                )
            )
        }
        guard let narrow = edge(.standard) else {
            return XCTFail("Expected narrow edge")
        }
        for legacyWidth in [CanvasEdgeWidth.medium, .wide, .legacyNarrow] {
            guard let rendered = edge(legacyWidth) else {
                return XCTFail("Expected legacy width edge")
            }
            XCTAssertEqual(try pngData(narrow), try pngData(rendered))
        }
    }

    func testEffectWidthDoesNotMovePartitionPhotoMask() throws {
        let canvasSize = CGSize(width: 640, height: 400)
        func mask(_ width: CanvasEdgeWidth) -> CGImage? {
            BackgroundMaskRenderer.maskImage(
                size: canvasSize,
                settings: BackgroundElementSettings(
                    edgeStyle: .tornLayered,
                    edgeWidth: width,
                    splitCount: .four,
                    dividerAngle: 90,
                    selectedPartition: 0
                )
            )
        }
        guard let narrow = mask(.standard), let wide = mask(.wide) else {
            return XCTFail("Expected both partition masks")
        }
        XCTAssertEqual(try pngData(narrow), try pngData(wide))
    }

    func testWriteCanvasEdgeWidthComparisonWhenRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["CANVAS_EDGE_WIDTHS_OUTPUT"] else {
            throw XCTSkip("Set CANVAS_EDGE_WIDTHS_OUTPUT to write the width comparison")
        }
        let canvasSize = CGSize(width: 640, height: 400)
        guard let source = solidImage(
            size: canvasSize,
            color: CGColor(red: 0.12, green: 0.55, blue: 0.82, alpha: 1)
        ) else { return XCTFail("Expected source image") }
        let store = BackgroundStore.shared
        guard let imageID = store.saveUserImage(try pngData(source), preferredFileExtension: "png") else {
            return XCTFail("Expected stored source image")
        }
        defer { try? FileManager.default.removeItem(at: store.mediaURL(named: imageID)) }

        let widths = CanvasEdgeWidth.allCases
        let cards = widths.compactMap { width -> CGImage? in
            let composition = Composition(
                name: width.title,
                canvas: CanvasSpec(width: canvasSize.width, height: canvasSize.height),
                duration: 1,
                elements: [CompositionElement(
                    kind: .background(backgroundID: imageID),
                    name: width.title,
                    startTime: 0,
                    endTime: 1
                )],
                background: BackgroundPreset(kind: .solid, topColor: "DDE5EE", bottomColor: "DDE5EE"),
                canvasEdgeStyle: .tornLayered,
                canvasEdgeWidth: width
            )
            return CompositionRenderer().render(composition, at: 0)
        }
        XCTAssertEqual(cards.count, widths.count)
        guard let preview = ProceduralRasterRenderer.makeImage(
            size: CGSize(width: 2_080, height: 520),
            transparent: false,
            draw: { context, rect in
                context.setFillColor(CGColor(red: 0.90, green: 0.93, blue: 0.96, alpha: 1))
                context.fill(rect)
                for (index, card) in cards.enumerated() {
                    context.draw(card, in: CGRect(x: 40 + CGFloat(index) * 680, y: 60, width: 640, height: 400))
                }
            }
        ) else { return XCTFail("Expected width comparison") }
        try write(preview, to: URL(fileURLWithPath: outputPath))
    }

    func testWritePartitionPaperEdgeWhenRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["PARTITION_PAPER_EDGE_OUTPUT"] else {
            throw XCTSkip("Set PARTITION_PAPER_EDGE_OUTPUT to write the partition preview")
        }
        let canvasSize = CGSize(width: 960, height: 600)
        let colors = [
            CGColor(red: 0.10, green: 0.42, blue: 0.70, alpha: 1),
            CGColor(red: 0.94, green: 0.55, blue: 0.13, alpha: 1),
            CGColor(red: 0.18, green: 0.66, blue: 0.48, alpha: 1),
            CGColor(red: 0.73, green: 0.27, blue: 0.47, alpha: 1)
        ]
        let store = BackgroundStore.shared
        let imageIDs = try colors.map { color -> String in
            guard let source = solidImage(size: canvasSize, color: color),
                  let id = store.saveUserImage(try pngData(source), preferredFileExtension: "png") else {
                throw NSError(domain: "PaperEffectRendererSnapshotTests", code: 3)
            }
            return id
        }
        defer { imageIDs.forEach { try? FileManager.default.removeItem(at: store.mediaURL(named: $0)) } }

        let cards = CanvasEdgeWidth.allCases.compactMap { width -> CGImage? in
            let elements = imageIDs.enumerated().map { index, imageID in
                CompositionElement(
                    kind: .background(backgroundID: imageID),
                    name: "partition-\(index)",
                    zIndex: index,
                    startTime: 0,
                    endTime: 1,
                    backgroundSettings: BackgroundElementSettings(
                        edgeStyle: .tornLayered,
                        edgeWidth: width,
                        splitCount: .four,
                        dividerAngle: 90,
                        selectedPartition: index
                    )
                )
            }
            let composition = Composition(
                name: "Paper partitions \(width.title)",
                canvas: CanvasSpec(width: canvasSize.width, height: canvasSize.height),
                duration: 1,
                elements: elements
            )
            return CompositionRenderer().render(composition, at: 0)
        }
        XCTAssertEqual(cards.count, CanvasEdgeWidth.allCases.count)
        guard let preview = ProceduralRasterRenderer.makeImage(
            size: CGSize(width: 2_080, height: 520),
            transparent: false,
            draw: { context, rect in
                context.setFillColor(CGColor(red: 0.90, green: 0.93, blue: 0.96, alpha: 1))
                context.fill(rect)
                for (index, card) in cards.enumerated() {
                    context.draw(card, in: CGRect(x: 40 + CGFloat(index) * 680, y: 60, width: 640, height: 400))
                }
            }
        ) else { return XCTFail("Expected partition comparison") }
        try write(preview, to: URL(fileURLWithPath: outputPath))
    }

    func testLayeredCanvasEdgeMasksFullBleedContent() throws {
        let canvasSize = CGSize(width: 640, height: 400)
        guard let source = ProceduralRasterRenderer.makeImage(
            size: canvasSize,
            transparent: false,
            draw: { context, rect in
                context.setFillColor(CGColor(red: 0.95, green: 0.05, blue: 0.55, alpha: 1))
                context.fill(rect)
            }
        ) else {
            return XCTFail("Expected source image")
        }
        let store = BackgroundStore.shared
        guard let imageID = store.saveUserImage(try pngData(source), preferredFileExtension: "png") else {
            return XCTFail("Expected stored source image")
        }
        defer { try? FileManager.default.removeItem(at: store.mediaURL(named: imageID)) }

        let composition = Composition(
            name: "Canvas edge mask",
            canvas: CanvasSpec(width: canvasSize.width, height: canvasSize.height),
            duration: 1,
            elements: [
                CompositionElement(
                    kind: .background(backgroundID: imageID),
                    name: "full bleed",
                    startTime: 0,
                    endTime: 1
                )
            ],
            background: BackgroundPreset(
                kind: .solid,
                topColor: "DDE5EE",
                bottomColor: "DDE5EE"
            ),
            canvasEdgeStyle: .tornLayered,
            canvasEdgeWidth: .wide
        )
        guard let rendered = CompositionRenderer().render(composition, at: 0) else {
            return XCTFail("Expected rendered canvas")
        }

        let center = rgba(in: rendered, x: rendered.width / 2, y: rendered.height / 2)
        let corner = rgba(in: rendered, x: 2, y: 2)
        XCTAssertGreaterThan(center.red, 200)
        XCTAssertLessThan(center.green, 60)
        XCTAssertGreaterThan(center.blue, 100)
        XCTAssertFalse(corner.red > 200 && corner.green < 60 && corner.blue > 100)

        if let outputPath = ProcessInfo.processInfo.environment["CANVAS_EDGE_COMPOSITION_OUTPUT"] {
            try write(rendered, to: URL(fileURLWithPath: outputPath))
        }
    }

    /// Outputs all three production styles in one image for visual comparison
    /// with the authored A/B/C reference.
    func testWritePaperStyleTriptychWhenRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["PAPER_EFFECT_TRIPTYCH_OUTPUT"] else {
            throw XCTSkip("Set PAPER_EFFECT_TRIPTYCH_OUTPUT to write the A/B/C visual snapshot")
        }

        let cardSize = CGSize(width: 480, height: 620)
        let profiles: [(TornEdgeProfile, CGFloat, PaperFoldCorner?)] = [
            (.soft, 38, nil),
            (.fibrous, 52, nil),
            (.layered, 58, .bottomRight)
        ]
        let cards = profiles.compactMap { profile, inset, corner -> CGImage? in
            guard let overlay = PaperEffectRenderer.borderOverlay(
                size: cardSize,
                profile: profile,
                borderInset: inset,
                foldedCorner: corner
            ) else { return nil }
            return ProceduralRasterRenderer.makeImage(size: cardSize) { context, rect in
                drawPreviewContent(in: context, rect: rect)
                context.draw(overlay, in: rect)
            }
        }
        XCTAssertEqual(cards.count, profiles.count)

        let previewSize = CGSize(width: 1_660, height: 780)
        guard let preview = ProceduralRasterRenderer.makeImage(
            size: previewSize,
            transparent: false,
            draw: { context, rect in
                context.setFillColor(CGColor(red: 0.90, green: 0.93, blue: 0.96, alpha: 1))
                context.fill(rect)
                for (index, card) in cards.enumerated() {
                    context.draw(card, in: CGRect(x: 70 + CGFloat(index) * 530, y: 80, width: cardSize.width, height: cardSize.height))
                }
            }
        ) else {
            return XCTFail("Expected paper style triptych")
        }

        try write(preview, to: URL(fileURLWithPath: outputPath))
    }

    /// 本地视觉回归工具：设置 PAPER_EFFECT_PREVIEW_OUTPUT 后输出真实渲染快照。
    /// 它直接调用生产代码，不维护另一套“看起来差不多”的预览实现。
    func testWriteLayeredPaperPreviewWhenRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["PAPER_EFFECT_PREVIEW_OUTPUT"] else {
            throw XCTSkip("Set PAPER_EFFECT_PREVIEW_OUTPUT to write a visual snapshot")
        }

        let cardSize = CGSize(width: 1_200, height: 760)
        guard let overlay = PaperEffectRenderer.borderOverlay(
            size: cardSize,
            profile: .layered,
            borderInset: 82,
            foldedCorner: .bottomRight
        ), let card = ProceduralRasterRenderer.makeImage(size: cardSize, draw: { context, rect in
            drawPreviewContent(in: context, rect: rect)
            context.draw(overlay, in: rect)
        }), let preview = ProceduralRasterRenderer.makeImage(
            size: CGSize(width: 1_400, height: 960),
            transparent: false,
            draw: { context, rect in
                context.setFillColor(CGColor(red: 0.90, green: 0.91, blue: 0.94, alpha: 1))
                context.fill(rect)
                context.draw(card, in: CGRect(x: 100, y: 100, width: cardSize.width, height: cardSize.height))
            }
        ) else {
            return XCTFail("Expected paper effect preview")
        }

        try write(preview, to: URL(fileURLWithPath: outputPath))
    }

    private func write(_ image: CGImage, to outputURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return XCTFail("Could not create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "PaperEffectRendererSnapshotTests", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PaperEffectRendererSnapshotTests", code: 2)
        }
        return data as Data
    }

    private func solidImage(size: CGSize, color: CGColor) -> CGImage? {
        ProceduralRasterRenderer.makeImage(size: size, transparent: false) { context, rect in
            context.setFillColor(color)
            context.fill(rect)
        }
    }

    private func rgba(in image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return (-1, -1, -1, -1)
        }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return (-1, -1, -1, -1) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }

    private func drawPreviewContent(in context: CGContext, rect: CGRect) {
        let left = CGRect(x: 0, y: 0, width: rect.width / 2, height: rect.height)
        let right = CGRect(x: rect.width / 2, y: 0, width: rect.width / 2, height: rect.height)
        drawGradient(
            in: context,
            rect: left,
            colors: [
                CGColor(red: 0.10, green: 0.27, blue: 0.46, alpha: 1),
                CGColor(red: 0.63, green: 0.82, blue: 0.91, alpha: 1)
            ]
        )
        drawGradient(
            in: context,
            rect: right,
            colors: [
                CGColor(red: 0.96, green: 0.62, blue: 0.12, alpha: 1),
                CGColor(red: 0.27, green: 0.08, blue: 0.10, alpha: 1)
            ]
        )

        context.setFillColor(CGColor(gray: 0.03, alpha: 0.72))
        for index in 0..<13 {
            let width = CGFloat(45 + (index * 17) % 65)
            let height = CGFloat(75 + (index * 43) % 180)
            let x = CGFloat(index) * (rect.width / 12) - 20
            context.fill(CGRect(x: x, y: 70, width: width, height: height))
        }
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
        context.setLineWidth(4)
        context.move(to: CGPoint(x: rect.midX, y: 0))
        context.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        context.strokePath()
    }

    private func drawGradient(in context: CGContext, rect: CGRect, colors: [CGColor]) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(
                  colorsSpace: colorSpace,
                  colors: colors as CFArray,
                  locations: [0, 1]
              ) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: []
        )
        context.restoreGState()
    }
}
