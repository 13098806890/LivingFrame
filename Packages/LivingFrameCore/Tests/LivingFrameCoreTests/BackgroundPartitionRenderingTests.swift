import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LivingFrameCore

final class BackgroundPartitionRenderingTests: XCTestCase {
    func testFourBackgroundsRenderIntoFourIndependentPartitions() throws {
        let colors = [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        ]
        let store = BackgroundStore.shared
        let imageIDs = try colors.map { color in
            guard let id = store.saveUserImage(try pngData(fill: color), preferredFileExtension: "png") else {
                throw NSError(domain: "LivingFrameCoreTests", code: 1)
            }
            return id
        }
        defer {
            for id in imageIDs {
                try? FileManager.default.removeItem(at: store.mediaURL(named: id))
            }
        }

        let elements = imageIDs.enumerated().map { index, imageID in
            CompositionElement(
                kind: .background(backgroundID: imageID),
                name: "partition-\(index)",
                transform: ElementTransform(position: CGPoint(x: 80, y: 80)),
                zIndex: index,
                startTime: 0,
                endTime: 1,
                backgroundSettings: BackgroundElementSettings(
                    splitCount: .four,
                    dividerAngle: 0,
                    selectedPartition: index
                )
            )
        }
        let composition = Composition(
            name: "Four partitions",
            canvas: CanvasSpec(width: 160, height: 160),
            duration: 1,
            elements: elements
        )

        guard let result = CompositionRenderer().render(composition, at: 0) else {
            return XCTFail("Expected a rendered frame")
        }

        // 四个采样点不依赖 Core Graphics 的行原点约定；只要四个分区都被独立
        // 合成，采样集合就必须恰好包含四种源色。若遮罩被复用为同一个分区，会留下
        // 白色底图并立刻让这个断言失败。
        let samples = [
            rgb(in: result, x: 40, y: 40),
            rgb(in: result, x: 120, y: 40),
            rgb(in: result, x: 40, y: 120),
            rgb(in: result, x: 120, y: 120)
        ]
        let expected = [
            RGB(red: 255, green: 0, blue: 0),
            RGB(red: 0, green: 255, blue: 0),
            RGB(red: 0, green: 0, blue: 255),
            RGB(red: 255, green: 255, blue: 0)
        ]
        let nearest = samples.map { sample in
            expected.indices.min { colorDistance(sample, expected[$0]) < colorDistance(sample, expected[$1]) }!
        }
        XCTAssertEqual(Set(nearest), Set(expected.indices))
        for sample in samples {
            XCTAssertLessThanOrEqual(expected.map { colorDistance(sample, $0) }.min()!, 70)
        }
    }

    private func pngData(fill color: CGColor) throws -> Data {
        let size = 16
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "LivingFrameCoreTests", code: 2)
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else {
            throw NSError(domain: "LivingFrameCoreTests", code: 3)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "LivingFrameCoreTests", code: 4)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "LivingFrameCoreTests", code: 5)
        }
        return data as Data
    }

    private func rgb(in image: CGImage, x: Int, y: Int) -> RGB {
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
            return RGB(red: -1, green: -1, blue: -1)
        }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return RGB(red: -1, green: -1, blue: -1) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return RGB(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }

    private func colorDistance(_ lhs: RGB, _ rhs: RGB) -> Int {
        abs(lhs.red - rhs.red) + abs(lhs.green - rhs.green) + abs(lhs.blue - rhs.blue)
    }

    private struct RGB: Hashable {
        let red: Int
        let green: Int
        let blue: Int
    }
}
