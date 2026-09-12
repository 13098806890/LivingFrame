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
}
