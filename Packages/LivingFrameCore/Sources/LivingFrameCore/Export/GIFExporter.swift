import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: Error {
    case renderFailed
    case destinationFailed
    case cancelled
}

/// GIF 导出（ImageIO）：alpha 为 1-bit，适合硬边风格
public struct GIFExporter {
    public init() {}

    public func export(
        _ composition: Composition,
        to url: URL,
        fps: Double = 15,
        progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) async throws {
        let frameCount = max(1, Int(composition.duration * fps))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { throw ExportError.destinationFailed }

        let loopProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, loopProperties as CFDictionary)

        let renderer = CompositionRenderer()
        for index in 0..<frameCount {
            if isCancelled() || Task.isCancelled {
                throw ExportError.cancelled
            }
            guard let frame = renderer.render(composition, at: Double(index) / fps) else { continue }
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]
            ]
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
            progress(Double(index + 1) / Double(frameCount))
        }

        guard CGImageDestinationFinalize(destination) else { throw ExportError.destinationFailed }
    }
}
