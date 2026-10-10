import CoreGraphics
import ImageIO
import XCTest
@testable import LivingFrameCore

final class GIFExporterTests: XCTestCase {
    func testTransparent720p15FPSLoopingExport() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transparent-720p-15fps-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let composition = Composition(
            name: "Transparent material",
            canvas: CanvasSpec(width: 800, height: 400),
            duration: 1.0 / 15.0,
            fps: 15,
            background: .clear
        )

        try await GIFExporter().export(
            composition,
            to: url,
            fps: 15,
            maxPixelSize: 720,
            loops: true
        )

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(frame.width, 720)
        XCTAssertEqual(frame.height, 360)

        let frameProperties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let gifProperties = try XCTUnwrap(
            frameProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        )
        let delay = try XCTUnwrap(gifProperties[kCGImagePropertyGIFDelayTime] as? NSNumber)
        XCTAssertEqual(delay.doubleValue, 1.0 / 15.0, accuracy: 0.01)

        let containerProperties = try XCTUnwrap(
            CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        )
        let containerGIF = try XCTUnwrap(
            containerProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        )
        XCTAssertEqual((containerGIF[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 0)

        var pixel = [UInt8](repeating: 255, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(pixel[3], 0)
    }

    func testExportUsesClipSnapshotAfterFrameCacheMutation() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-export-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frame = try XCTUnwrap(makeEdgeSubjectFrame())
        XCTAssertTrue(writePNG(frame, to: folder.appendingPathComponent("00000.png")))

        let clipID = "gif-export-snapshot"
        let exportedClip = SegmentedClip(
            id: clipID,
            name: "GIF snapshot",
            fps: 1,
            frameCount: 1,
            width: 100,
            height: 100,
            folderURL: folder,
            edgeStyle: .outline,
            edgeThickness: .thin,
            stickerStyle: .comic
        )
        var changedClip = exportedClip
        changedClip.edgeStyle = .none
        changedClip.stickerStyle = .none
        FrameCache.shared.registerInMemory(exportedClip)

        let composition = Composition(
            name: "GIF snapshot",
            canvas: CanvasSpec(width: 220, height: 220),
            duration: 2,
            fps: 1,
            elements: [CompositionElement(
                kind: .clip(clipID: clipID),
                name: exportedClip.name,
                transform: ElementTransform(position: CGPoint(x: 110, y: 110)),
                endTime: 2,
                sourceEndTime: 1
            )],
            background: .clear
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-export-snapshot-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let mutation = MutationBox()

        try await GIFExporter().export(
            composition,
            to: url,
            fps: 1,
            maxPixelSize: 220,
            loops: true,
            clipSnapshots: [clipID: exportedClip],
            progress: { fraction in
                guard fraction >= 0.5, !mutation.didMutate else { return }
                mutation.didMutate = true
                FrameCache.shared.registerInMemory(changedClip)
            }
        )

        XCTAssertTrue(mutation.didMutate)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let second = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 1, nil))
        let firstPixels = try XCTUnwrap(CGImageTestSupport.rgbaPixels(in: first))
        let secondPixels = try XCTUnwrap(CGImageTestSupport.rgbaPixels(in: second))
        XCTAssertEqual(visibleAlphaBounds(in: first), visibleAlphaBounds(in: second))
        XCTAssertTrue(
            firstPixels == secondPixels,
            "GIF frames must use one immutable clip value for the whole export"
        )
    }

    private final class MutationBox {
        var didMutate = false
    }

    private func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private func makeEdgeSubjectFrame() -> CGImage? {
        let size = CGSize(width: 100, height: 100)
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
        context.setFillColor(CGColor(red: 0.2, green: 0.65, blue: 0.9, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()
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
        }) else { return nil }

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

}
