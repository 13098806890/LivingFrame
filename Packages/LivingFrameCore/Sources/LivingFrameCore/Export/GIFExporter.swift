import Foundation
import CoreImage
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
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async throws {
        let frameCount = max(1, Int(composition.duration * fps))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { throw ExportError.destinationFailed }
        let start = Date()
        LogStore.log("GIFExporter: start frames=\(frameCount) fps=\(fps) size=\(Int(composition.canvas.width))x\(Int(composition.canvas.height)) url=\(url.path)")
        var memory = ExportMemoryDiagnostics(exporter: "GIF", frameCount: frameCount)
        memory.log("start")

        let renderContext = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false
        ])
        let renderer = CompositionRenderer(context: renderContext)
        defer { renderContext.clearCaches() }
        var skipped = 0
        for index in 0..<frameCount {
            if isCancelled() || Task.isCancelled {
                throw ExportError.cancelled
            }
            let shouldLogMemory = memory.shouldLog(frame: index, totalFrames: frameCount)
            if shouldLogMemory {
                memory.log("before-render", frame: index + 1, totalFrames: frameCount)
            }
            let frameStart = Date()
            let added = autoreleasepool { () -> Bool in
                guard let frame = renderer.render(composition, at: Double(index) / fps) else {
                    return false
                }
                let frameProperties = [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]
                ]
                CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
                return true
            }
            guard added else {
                skipped += 1
                continue
            }
            if (index + 1).isMultiple(of: 10) {
                renderContext.clearCaches()
            }
            if shouldLogMemory {
                memory.log("after-add-image", frame: index + 1, totalFrames: frameCount)
            }
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

        memory.log("before-finalize")
        guard CGImageDestinationFinalize(destination) else {
            LogStore.log("GIFExporter: Finalize failed")
            throw ExportError.destinationFailed
        }
        memory.log("after-finalize")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log("GIFExporter: done elapsed=\(Int(Date().timeIntervalSince(start)))s skipped=\(skipped) size=\(size) bytes")
    }
}
