import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Live Photo 导出：H.264 视频（≤3 秒）+ 封面 JPEG，供 PHAssetCreationRequest 配对保存。
/// 视频与封面写入一致的 AssetIdentifier（QuickTime 元数据 + EXIF MakerApple），
/// 缺少该标识会导致 PHPhotosErrorDomain 3302/3392 配对导入失败。
public struct LivePhotoExporter {
    public struct Output {
        public let videoURL: URL
        public let coverData: Data
    }

    /// 导出用软件渲染，避免 CIContext GPU 工作与 VideoToolbox 编码器争用导致 writer 卡死
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .useSoftwareRenderer: true
    ])

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
        let start = Date()
        let assetID = UUID().uuidString
        LogStore.log("LivePhotoExporter: start size=\(width)x\(height) frames=\(frameCount) assetID=\(assetID) url=\(url.path)")

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

        // 配对标识：文件级 QuickTime 元数据（moov 层，无需 adaptor）
        let identifierItem = AVMutableMetadataItem()
        identifierItem.identifier = AVMetadataIdentifier.quickTimeMetadataContentIdentifier
        identifierItem.value = assetID as NSString
        writer.metadata = [identifierItem]

        // 可选增强：定时元数据轨（部分系统需要从轨道读取标识；hint 创建失败则跳过，不阻塞导出）
        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if let formatHint = metadataFormatHint() {
            let input = AVAssetWriterInput(
                mediaType: .metadata,
                outputSettings: nil,
                sourceFormatHint: formatHint
            )
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
            if writer.canAdd(input) {
                writer.add(input)
                metadataInput = input
            }
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.startWriting() else {
            LogStore.log("LivePhotoExporter: startWriting failed status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
            throw ExportError.renderFailed
        }
        writer.startSession(atSourceTime: .zero)

        // 写入定时元数据轨（若可用）
        if let metadataInput, let metadataAdaptor {
            let metadataGroup = AVTimedMetadataGroup(
                items: [identifierItem],
                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
            )
            metadataAdaptor.append(metadataGroup)
            metadataInput.markAsFinished()
        }

        let renderer = CompositionRenderer(context: context)
        let rect = composition.canvasRect
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: rect)
        var coverData: Data?

        for index in 0..<frameCount {
            let stallStart = Date()
            var lastStallLog = Date()
            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    LogStore.log("LivePhotoExporter: writer failed mid-way index=\(index)/\(frameCount) error=\(String(describing: writer.error))")
                    throw ExportError.renderFailed
                }
                if Date().timeIntervalSince(stallStart) > 15 {
                    LogStore.log("LivePhotoExporter: ❌ writer stalled 15s, aborting export index=\(index)/\(frameCount) status=\(writer.status.rawValue)")
                    videoInput.markAsFinished()
                    await writer.finishWriting()
                    throw ExportError.renderFailed
                }
                if Date().timeIntervalSince(lastStallLog) > 5 {
                    LogStore.log("LivePhotoExporter: ⚠️ isReadyForMoreMediaData waiting > 5s index=\(index) status=\(writer.status.rawValue)")
                    lastStallLog = Date()
                }
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
                coverData = jpegData(from: ci, assetID: assetID)
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(composition.fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                LogStore.log("LivePhotoExporter: append failed index=\(index)/\(frameCount) status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
                throw ExportError.renderFailed
            }
            let fraction = Double(index + 1) / Double(frameCount)
            if index % 20 == 0 || index == frameCount - 1 {
                LogStore.log("LivePhotoExporter: frame \(index + 1)/\(frameCount) elapsed=\(Int(Date().timeIntervalSince(start)))s")
            }
            progress(fraction)
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            LogStore.log("LivePhotoExporter: finishWriting failed status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
            throw ExportError.renderFailed
        }
        guard let coverData else { throw ExportError.renderFailed }
        LogStore.log("LivePhotoExporter: done elapsed=\(Int(Date().timeIntervalSince(start)))s")

        return Output(videoURL: url, coverData: coverData)
    }

    /// QuickTime 元数据轨的格式描述 hint（metadata adaptor 必需）；失败返回 nil
    private func metadataFormatHint() -> CMFormatDescription? {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier.quickTimeMetadataContentIdentifier
        item.value = "" as NSString
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: item.identifier as Any
        ]
        var hint: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: 0x6D647461, // 'mdta' QuickTime metadata
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &hint
        )
        LogStore.log("LivePhotoExporter: metadata hint status=\(status) ok=\(hint != nil)")
        return hint
    }

    /// 封面 JPEG：写入 EXIF MakerApple 的 AssetIdentifier（key "17"），与视频轨配对
    private func jpegData(from ci: CIImage, assetID: String) -> Data? {
        guard let image = context.createCGImage(ci, from: ci.extent) else { return nil }
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  data, UTType.jpeg.identifier as CFString, 1, nil
              ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyMakerAppleDictionary: ["17": assetID]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
