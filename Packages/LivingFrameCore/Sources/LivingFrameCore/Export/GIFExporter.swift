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

/// 微信收藏 GIF 的实际输出信息，用于在界面上如实提示是否进行了均匀抽帧。
public struct ChatStickerExportResult: Sendable, Equatable {
    public let fps: Double
    public let pixelSize: Int

    public var usedFrameSampling: Bool { fps < 15 }
}

/// GIF 导出（ImageIO）：alpha 为 1-bit，适合硬边风格
public struct GIFExporter {
    public init() {}

    /// 微信 GIF：固定正方形、永久循环。超过 10 MiB 时只均匀抽帧，
    /// 从不降低像素尺寸或裁切画面。
    public func exportChatSticker(
        _ composition: Composition,
        to url: URL,
        pixelSize: CGFloat = 240,
        progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async throws -> ChatStickerExportResult {
        let outputPixelSize = min(max(pixelSize.rounded(), 1), 1000)
        let candidates: [Double] = [15, 12, 10, 8, 6]
        let workingURL = url.deletingLastPathComponent()
            .appendingPathComponent("LF-sticker-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: workingURL) }
        for (index, fps) in candidates.enumerated() {
            if isCancelled() || Task.isCancelled { throw ExportError.cancelled }
            try? FileManager.default.removeItem(at: workingURL)
            try await export(
                composition, to: workingURL, fps: fps,
                maxPixelSize: outputPixelSize,
                outputSize: CGSize(width: outputPixelSize, height: outputPixelSize),
                loops: true,
                progress: { fraction in
                    progress((Double(index) + fraction) / Double(candidates.count))
                },
                isCancelled: isCancelled
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: workingURL.path)
            let bytes = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
            LogStore.log("GIFSticker.highQuality size=\(Int(outputPixelSize)) fps=\(fps) bytes=\(bytes)")
            // 微信“添加到自定义表情”的收藏场景按 10 MiB 控制；这不是表情商店投稿的
            // 500 KB/100 KB 素材规范，不能混用。
            if bytes <= 10 * 1024 * 1024 {
                if isCancelled() || Task.isCancelled { throw ExportError.cancelled }
                try FileManager.default.moveItem(at: workingURL, to: url)
                progress(1)
                return ChatStickerExportResult(fps: fps, pixelSize: Int(outputPixelSize))
            }
        }
        throw ChatStickerError.tooLarge
    }

    public func export(
        _ composition: Composition,
        to url: URL,
        fps: Double = 15,
        maxPixelSize: CGFloat? = nil,
        outputSize: CGSize? = nil,
        loops: Bool = false,
        progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async throws {
        let frameCount = max(1, Int((composition.duration * fps).rounded(.up)))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { throw ExportError.destinationFailed }
        if loops {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
        }
        let start = Date()
        let exportSize = outputSize ?? composition.renderRect.size
        LogStore.log("GIFExporter: start frames=\(frameCount) fps=\(fps) size=\(Int(exportSize.width))x\(Int(exportSize.height)) url=\(url.path)")
        var memory = ExportMemoryDiagnostics(exporter: "GIF", frameCount: frameCount)
        memory.log("start")

        let renderContext = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false
        ])
        let renderer = CompositionRenderer(context: renderContext, frameMaxPixelSize: maxPixelSize)
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
                let outputFrame = outputSize.flatMap { gifCanvasFrame(frame, outputSize: $0) } ?? frame
                let frameProperties = [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]
                ]
                CGImageDestinationAddImage(destination, outputFrame, frameProperties as CFDictionary)
                return true
            }
            guard added else {
                // 表情模式不能跳过失败帧后缩短时间或输出不完整动画。
                if maxPixelSize != nil { throw ExportError.renderFailed }
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

    /// GIF 的每一帧必须同尺寸。把非 1:1 的编辑画布等比居中在透明正方形里，
    /// 既符合微信显示容器，也绝不擅自裁掉人物或贴纸。
    private func gifCanvasFrame(_ frame: CGImage, outputSize: CGSize) -> CGImage? {
        let width = max(Int(outputSize.width.rounded()), 1)
        let height = max(Int(outputSize.height.rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(frame.width), CGFloat(height) / CGFloat(frame.height))
        let size = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
        let rect = CGRect(x: (CGFloat(width) - size.width) / 2,
                          y: (CGFloat(height) - size.height) / 2,
                          width: size.width, height: size.height)
        context.interpolationQuality = .high
        context.draw(frame, in: rect)
        return context.makeImage()
    }
}

private enum ChatStickerError: LocalizedError {
    case tooLarge

    var errorDescription: String? {
        NSLocalizedString("高清微信表情在均匀抽帧至 6 fps 后仍超过 10 MB。为保留画面尺寸，未自动缩小；请缩短时间轴片段后再导出。", comment: "Chat sticker export error")
    }
}
