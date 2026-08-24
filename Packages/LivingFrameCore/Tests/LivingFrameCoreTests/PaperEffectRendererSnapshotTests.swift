import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LivingFrameCore

final class PaperEffectRendererSnapshotTests: XCTestCase {
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
