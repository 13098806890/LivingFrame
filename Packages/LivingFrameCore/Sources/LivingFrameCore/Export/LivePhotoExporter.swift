import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Live Photo 导出：H.264 视频（≤3 秒）+ 封面 JPEG，供 PHAssetCreationRequest 配对保存
public struct LivePhotoExporter {
    public struct Output {
        public let videoURL: URL
        public let coverData: Data
    }

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    public init() {}

    public func export(
        _ composition: Composition,
        to url: URL,
        progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) async throws -> Output {
        let width = max(2, Int(composition.canvas.width))
        let height = max(2, Int(composition.canvas.height))
        let duration = min(3, composition.duration)
        let frameCount = max(1, Int((duration * composition.fps).rounded(.up)))
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.renderFailed }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.startWriting() else { throw ExportError.renderFailed }
        writer.startSession(atSourceTime: .zero)

        let renderer = CompositionRenderer()
        let rect = composition.canvasRect
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: rect)
        var coverData: Data?

        for index in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 3_000_000)
            }
            if isCancelled() || Task.isCancelled {
                videoInput.markAsFinished()
                await writer.finishWriting()
                throw ExportError.cancelled
            }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.renderFailed }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { throw ExportError.renderFailed }
            // Live Photo 无透明通道：clear 背景填充为白色，保证不透明
            let source = renderer.renderCIImage(composition, at: Double(index) / composition.fps)
                ?? CIImage.clear.cropped(to: rect)
            let ci = source.composited(over: white)
            context.render(ci, to: buffer, bounds: rect, colorSpace: nil)
            if index == 0 {
                coverData = jpegData(from: ci)
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(composition.fps))
            guard adaptor.append(buffer, withPresentationTime: time) else { throw ExportError.renderFailed }
            progress(Double(index + 1) / Double(frameCount))
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.renderFailed }
        guard let coverData else { throw ExportError.renderFailed }

        return Output(videoURL: url, coverData: coverData)
    }

    private func jpegData(from ci: CIImage) -> Data? {
        guard let image = context.createCGImage(ci, from: ci.extent) else { return nil }
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  data, UTType.jpeg.identifier as CFString, 1, nil
              ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
