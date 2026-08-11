import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: Error {
    case renderFailed
    case destinationFailed
    case cancelled
    /// writer 停滞超时（多输入写入卡死）
    case writerStalled
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
        let start = Date()
        LogStore.log("GIFExporter: start frames=\(frameCount) fps=\(fps) size=\(Int(composition.canvas.width))x\(Int(composition.canvas.height)) url=\(url.path)")

        let loopProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, loopProperties as CFDictionary)

        let renderer = CompositionRenderer()
        var skipped = 0
        for index in 0..<frameCount {
            if isCancelled() || Task.isCancelled {
                throw ExportError.cancelled
            }
            let frameStart = Date()
            guard let frame = renderer.render(composition, at: Double(index) / fps) else {
                skipped += 1
                continue
            }
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]
            ]
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
            let frameCost = Date().timeIntervalSince(frameStart)
            if frameCost > 2 {
                LogStore.log("GIFExporter: ⚠️ frame \(index) render slow cost=\(Int(frameCost))s")
            }
            let fraction = Double(index + 1) / Double(frameCount)
            if index % 10 == 0 || fraction >= 1 {
                LogStore.log("GIFExporter: frame \(index + 1)/\(frameCount) elapsed=\(Int(Date().timeIntervalSince(start)))s")
            }
            progress(fraction)
        }

        guard CGImageDestinationFinalize(destination) else {
            LogStore.log("GIFExporter: Finalize failed")
            throw ExportError.destinationFailed
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log("GIFExporter: done elapsed=\(Int(Date().timeIntervalSince(start)))s skipped=\(skipped) size=\(size) bytes")
    }
}
