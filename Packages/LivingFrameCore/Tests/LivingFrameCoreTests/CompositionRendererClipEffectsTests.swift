import CoreGraphics
import ImageIO
import XCTest
@testable import LivingFrameCore

final class CompositionRendererClipEffectsTests: XCTestCase {
    func testSharedSubjectBoundsIgnoreTransparentMarginsAndFaintResidue() throws {
        let frame = try XCTUnwrap(makeSubjectFrame())

        let bounds = try XCTUnwrap(AlphaSubjectBounds.visiblePixelBounds(in: frame))
        // Core Graphics renders the CGImage into the y-up test context, so the
        // source rectangle's y coordinate is mirrored here.
        XCTAssertEqual(bounds, CGRect(x: 20, y: 35, width: 40, height: 30))
        XCTAssertEqual(
            AlphaSubjectBounds.subjectBase(
                in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height),
                bounds: bounds
            ),
            30,
            accuracy: 0.001
        )
    }

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

    func testStickerStyleThumbnailRendersEveryAvailableStyle() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sticker-style-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frame = try XCTUnwrap(makeTestFrame())
        XCTAssertTrue(writePNG(frame, to: folder.appendingPathComponent("00000.png")))

        let clip = SegmentedClip(
            id: "sticker-style-preview-\(UUID().uuidString)",
            name: "clip",
            fps: 1,
            frameCount: 1,
            width: 16,
            height: 16,
            folderURL: folder
        )
        FrameCache.shared.registerInMemory(clip)

        let renderer = CompositionRenderer(frameMaxPixelSize: 144)
        for style in StickerStyle.allCases {
            let thumbnail = try XCTUnwrap(
                renderer.stickerStyleThumbnail(for: clip, frameIndex: 0, style: style),
                "Expected a preview thumbnail for \(style.rawValue)"
            )
            XCTAssertGreaterThan(thumbnail.width, 0)
            XCTAssertGreaterThan(thumbnail.height, 0)
        }
    }

    func testStickerStyleThumbnailsUseSharedCanvasAndNormalizeSubjectZoom() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sticker-style-normalized-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let frame = try XCTUnwrap(makeOffCenterTestFrame())
        XCTAssertTrue(writePNG(frame, to: folder.appendingPathComponent("00000.png")))
        let clip = SegmentedClip(
            id: "sticker-style-normalized-\(UUID().uuidString)",
            name: "off-center clip",
            fps: 1,
            frameCount: 1,
            width: frame.width,
            height: frame.height,
            folderURL: folder
        )
        FrameCache.shared.registerInMemory(clip)

        let renderer = CompositionRenderer(frameMaxPixelSize: 144)
        var thumbnails: [CGImage] = []
        for style in StickerStyle.allCases {
            thumbnails.append(try XCTUnwrap(
                renderer.stickerStyleThumbnail(
                    for: clip,
                    frameIndex: 0,
                    style: style
                ),
                "Expected normalized preview for \(style.rawValue)"
            ))
        }
        let thumbnail = try XCTUnwrap(thumbnails.first)
        XCTAssertTrue(thumbnails.allSatisfy {
            $0.width == thumbnail.width && $0.height == thumbnail.height
        }, "Every style should use an identical preview canvas")
        XCTAssertEqual(thumbnail.width, 144)
        XCTAssertEqual(thumbnail.height, 114)

        let bounds = try XCTUnwrap(visibleAlphaBounds(in: thumbnail))
        XCTAssertEqual(bounds.midX, CGFloat(thumbnail.width) / 2, accuracy: 1.5)
        XCTAssertEqual(bounds.midY, CGFloat(thumbnail.height) / 2, accuracy: 1.5)
        XCTAssertEqual(bounds.width / CGFloat(thumbnail.width), 0.88, accuracy: 0.04)
        XCTAssertTrue(containsVisiblePixel(in: thumbnail))
    }

    func testElementFilterThumbnailsRenderEveryFilterOnSharedFraming() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("element-filter-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let frame = try XCTUnwrap(makeColorTestFrame())
        XCTAssertTrue(writePNG(frame, to: folder.appendingPathComponent("00000.png")))
        let clip = SegmentedClip(
            id: "element-filter-preview-\(UUID().uuidString)",
            name: "color clip",
            fps: 1,
            frameCount: 1,
            width: frame.width,
            height: frame.height,
            folderURL: folder
        )
        FrameCache.shared.registerInMemory(clip)
        let element = CompositionElement(
            kind: .clip(clipID: clip.id),
            name: clip.name,
            transform: ElementTransform(position: CGPoint(x: 8, y: 8)),
            endTime: 1,
            sourceEndTime: 1
        )
        let composition = Composition(
            name: "filter preview",
            canvas: CanvasSpec(width: 16, height: 16),
            duration: 1,
            fps: 1,
            elements: [element],
            background: .clear
        )
        let renderer = CompositionRenderer(frameMaxPixelSize: 144)
        var thumbnails: [CGImage] = []
        for filter in ElementFilter.allCases {
            thumbnails.append(try XCTUnwrap(
                renderer.elementFilterThumbnail(
                    for: element,
                    in: composition,
                    at: 0,
                    filter: filter
                ),
                "Expected a preview for filter \(filter.rawValue)"
            ))
        }

        XCTAssertTrue(thumbnails.allSatisfy { $0.width == 144 && $0.height == 114 })
        XCTAssertTrue(thumbnails.allSatisfy { containsVisiblePixel(in: $0) })
    }

    func testStyleAndFilterThumbnailsUseIdenticalSubjectZoom() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-option-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let frame = try XCTUnwrap(makeOffCenterTestFrame())
        XCTAssertTrue(writePNG(frame, to: folder.appendingPathComponent("00000.png")))
        let clip = SegmentedClip(
            id: "shared-option-preview-\(UUID().uuidString)",
            name: "shared preview clip",
            fps: 1,
            frameCount: 1,
            width: frame.width,
            height: frame.height,
            folderURL: folder
        )
        FrameCache.shared.registerInMemory(clip)

        let element = CompositionElement(
            kind: .clip(clipID: clip.id),
            name: clip.name,
            transform: ElementTransform(position: CGPoint(x: 40, y: 40)),
            endTime: 1,
            sourceEndTime: 1
        )
        let composition = Composition(
            name: "shared option preview",
            canvas: CanvasSpec(width: 80, height: 80),
            duration: 1,
            fps: 1,
            elements: [element],
            background: .clear
        )
        let renderer = CompositionRenderer(frameMaxPixelSize: 144)
        let styleThumbnail = try XCTUnwrap(
            renderer.stickerStyleThumbnail(for: clip, frameIndex: 0, style: .none)
        )
        let filterThumbnail = try XCTUnwrap(
            renderer.elementFilterThumbnail(
                for: element,
                in: composition,
                at: 0,
                filter: .none
            )
        )

        XCTAssertEqual(styleThumbnail.width, filterThumbnail.width)
        XCTAssertEqual(styleThumbnail.height, filterThumbnail.height)
        XCTAssertEqual(visibleAlphaBounds(in: styleThumbnail), visibleAlphaBounds(in: filterThumbnail))
    }

    private func visibleAlphaBounds(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard pixels.withUnsafeMutableBytes({ buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }) else {
            return nil
        }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * bytesPerRow + x * 4 + 3] > 24 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
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

    private func makeSubjectFrame() -> CGImage? {
        let size = CGSize(width: 100, height: 80)
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

        // This is below the shared threshold and represents faint segmentation
        // residue that must not change the subject framing or effect scale.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.05))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 15, width: 40, height: 30))
        return context.makeImage()
    }

    private func makeOffCenterTestFrame() -> CGImage? {
        let size = CGSize(width: 80, height: 80)
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
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 7, y: 48, width: 18, height: 12))
        return context.makeImage()
    }

    private func makeColorTestFrame() -> CGImage? {
        let size = CGSize(width: 16, height: 16)
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
        context.setFillColor(CGColor(red: 0.95, green: 0.12, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 3, y: 3, width: 5, height: 10))
        context.setFillColor(CGColor(red: 0.08, green: 0.9, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 8, y: 3, width: 5, height: 10))
        context.setFillColor(CGColor(red: 0.08, green: 0.2, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 5, y: 8, width: 6, height: 5))
        return context.makeImage()
    }

    private func containsVisiblePixel(in image: CGImage) -> Bool {
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        guard pixels.withUnsafeMutableBytes({ buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }) else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 12 }
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
