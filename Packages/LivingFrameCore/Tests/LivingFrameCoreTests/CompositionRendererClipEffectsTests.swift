import CoreGraphics
import ImageIO
import XCTest
@testable import LivingFrameCore

final class CompositionRendererClipEffectsTests: XCTestCase {
    func testRendererCanDisableClipVisualEffects() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-effects-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frame = try XCTUnwrap(makeTestFrame())
        XCTAssertTrue(writePNG(frame, to: folder.appendingPathComponent("00000.png")))

        let clip = SegmentedClip(
            id: "clip-effects",
            name: "clip",
            fps: 1,
            frameCount: 1,
            width: 16,
            height: 16,
            folderURL: folder,
            edgeStyle: .outline,
            stickerStyle: .comic
        )
        FrameCache.shared.registerInMemory(clip)

        let composition = Composition(
            name: "clip effects",
            canvas: CanvasSpec(width: 16, height: 16),
            duration: 1,
            fps: 1,
            elements: [CompositionElement(
                kind: .clip(clipID: clip.id),
                name: clip.name,
                transform: ElementTransform(position: CGPoint(x: 8, y: 8)),
                endTime: 1,
                sourceEndTime: 1
            )],
            background: .clear
        )

        let plain = try XCTUnwrap(CompositionRenderer(appliesClipEffects: false).render(composition, at: 0))
        let styled = try XCTUnwrap(CompositionRenderer(appliesClipEffects: true).render(composition, at: 0))
        XCTAssertEqual(alpha(in: plain, x: 0, y: 0), 0)
        XCTAssertGreaterThan(alpha(in: styled, x: 0, y: 0), 0)
    }

    private func makeTestFrame() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: 16, height: 16))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 7, y: 7, width: 2, height: 2))
        return context.makeImage()
    }

    private func alpha(in image: CGImage, x: Int, y: Int) -> Int {
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return -1 }
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return Int(data.bindMemory(to: UInt8.self, capacity: 4)[3])
    }
}
