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
        public let assetIdentifier: String
    }

    /// 导出用软件渲染，避免 CIContext GPU 工作与 VideoToolbox 编码器争用导致 writer 卡死
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .useSoftwareRenderer: true,
        .cacheIntermediates: false
    ])

    public init() {}

    public func export(
        _ composition: Composition,
        to url: URL,
        progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async throws -> Output {
        let renderSize = composition.renderRect.size
        let width = max(2, Int(renderSize.width))
        let height = max(2, Int(renderSize.height))
        let duration = min(3, composition.duration)
        let frameCount = max(1, Int((duration * composition.fps).rounded(.up)))
        try? FileManager.default.removeItem(at: url)
        let start = Date()
        let assetID = UUID().uuidString
        LogStore.log("xdz.livephoto.exporter start size=\(width)x\(height) frames=\(frameCount) assetID=\(assetID) url=\(url.path)")

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
        guard writer.canAdd(videoInput) else {
            LogStore.log("xdz.livephoto.exporter cannot add video input")
            throw ExportError.renderFailed
        }
        writer.add(videoInput)

        // 配对标识：文件级 QuickTime 元数据（moov 层，无需 adaptor）。
        // 必须同时设置 keySpace、key 和 dataType，Photos 才能稳定识别。
        let identifierItem = AVMutableMetadataItem()
        identifierItem.key = "com.apple.quicktime.content.identifier" as NSString
        identifierItem.keySpace = AVMetadataKeySpace.quickTimeMetadata
        identifierItem.value = assetID as NSString
        identifierItem.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [identifierItem]

        // Live Photo 必需的 still-image-time 定时元数据轨。
        // 本实现的封面是第 0 帧，所以元数据样本也从第 0 帧开始。
        guard let stillImageTimeHint = stillImageTimeFormatHint() else {
            throw ExportError.renderFailed
        }
        let stillImageTimeInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: stillImageTimeHint
        )
        guard writer.canAdd(stillImageTimeInput) else {
            LogStore.log("xdz.livephoto.exporter cannot add still-image-time metadata input")
            throw ExportError.renderFailed
        }
        writer.add(stillImageTimeInput)
        let stillImageTimeAdaptor = AVAssetWriterInputMetadataAdaptor(
            assetWriterInput: stillImageTimeInput
        )

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        defer {
            context.clearCaches()
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolFlush(pool, .excessBuffers)
            }
        }

        guard writer.startWriting() else {
            LogStore.log("xdz.livephoto.exporter startWriting failed status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
            throw ExportError.renderFailed
        }
        writer.startSession(atSourceTime: .zero)

        let stillImageTimeItem = AVMutableMetadataItem()
        stillImageTimeItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillImageTimeItem.keySpace = AVMetadataKeySpace.quickTimeMetadata
        stillImageTimeItem.value = NSNumber(value: 0)
        stillImageTimeItem.dataType = "com.apple.metadata.datatype.int8"
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(composition.fps, 1)))
        let stillImageTimeGroup = AVTimedMetadataGroup(
            items: [stillImageTimeItem],
            timeRange: CMTimeRange(start: .zero, duration: frameDuration)
        )
        guard stillImageTimeAdaptor.append(stillImageTimeGroup) else {
            LogStore.log("xdz.livephoto.exporter append still-image-time metadata failed")
            throw ExportError.renderFailed
        }
        stillImageTimeInput.markAsFinished()

        let renderer = CompositionRenderer(context: context)
        let rect = composition.canvasRect
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: rect)
        var coverData: Data?
        var memory = ExportMemoryDiagnostics(exporter: "LivePhoto", frameCount: frameCount)
        memory.log("start-video-track")

        for index in 0..<frameCount {
            let stallStart = Date()
            var lastStallLog = Date()
            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    LogStore.log("xdz.livephoto.exporter writer failed mid-way index=\(index)/\(frameCount) error=\(String(describing: writer.error))")
                    throw ExportError.renderFailed
                }
                if Date().timeIntervalSince(stallStart) > 15 {
                    LogStore.log("xdz.livephoto.exporter ❌ writer stalled 15s, aborting export index=\(index)/\(frameCount) status=\(writer.status.rawValue)")
                    videoInput.markAsFinished()
                    await writer.finishWriting()
                    throw ExportError.renderFailed
                }
                if Date().timeIntervalSince(lastStallLog) > 5 {
                    LogStore.log("xdz.livephoto.exporter ⚠️ isReadyForMoreMediaData waiting > 5s index=\(index) status=\(writer.status.rawValue)")
                    lastStallLog = Date()
                }
                try await Task.sleep(nanoseconds: 3_000_000)
            }
            if isCancelled() || Task.isCancelled {
                videoInput.markAsFinished()
                await writer.finishWriting()
                throw ExportError.cancelled
            }
            let shouldLogMemory = memory.shouldLog(frame: index, totalFrames: frameCount)
            if shouldLogMemory {
                memory.log("before-buffer", frame: index + 1, totalFrames: frameCount)
            }
            let generatedCover = try autoreleasepool { () throws -> Data? in
                guard let pool = adaptor.pixelBufferPool else { throw ExportError.renderFailed }
                var pixelBuffer: CVPixelBuffer?
                let createStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard createStatus == kCVReturnSuccess, let buffer = pixelBuffer else {
                    LogStore.log("xdz.livephoto.exporter pixel buffer allocation failed index=\(index) status=\(createStatus)")
                    throw ExportError.renderFailed
                }
                // Live Photo 无透明通道：clear 背景填充为白色，保证不透明
                let source = renderer.renderCIImage(composition, at: Double(index) / composition.fps)
                    ?? CIImage.clear.cropped(to: rect)
                let ci = source.composited(over: white)
                context.render(ci, to: buffer, bounds: rect, colorSpace: nil)
                let firstFrameCover = index == 0 ? jpegData(from: ci, assetID: assetID) : nil
                let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(composition.fps))
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    LogStore.log("xdz.livephoto.exporter append failed index=\(index)/\(frameCount) status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
                    throw ExportError.renderFailed
                }
                pixelBuffer = nil
                return firstFrameCover
            }
            if let generatedCover {
                coverData = generatedCover
            }
            if (index + 1).isMultiple(of: 10) {
                context.clearCaches()
            }
            if shouldLogMemory {
                memory.log("after-append", frame: index + 1, totalFrames: frameCount)
            }
            let fraction = Double(index + 1) / Double(frameCount)
            if index % 20 == 0 || index == frameCount - 1 {
                LogStore.log("xdz.livephoto.exporter frame \(index + 1)/\(frameCount) elapsed=\(Int(Date().timeIntervalSince(start)))s")
            }
            progress(fraction)
        }
        memory.log("before-finish-writing")
        videoInput.markAsFinished()
        await writer.finishWriting()
        memory.log("after-finish-writing")
        guard writer.status == .completed else {
            LogStore.log("xdz.livephoto.exporter finishWriting failed status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
            throw ExportError.renderFailed
        }
        guard let coverData else {
            LogStore.log("xdz.livephoto.exporter cover JPEG is missing after rendering")
            throw ExportError.renderFailed
        }
        let videoBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log(
            "xdz.livephoto.exporter done elapsed=\(Int(Date().timeIntervalSince(start)))s "
                + "videoBytes=\(videoBytes) coverBytes=\(coverData.count) assetID=\(assetID)"
        )

        return Output(videoURL: url, coverData: coverData, assetIdentifier: assetID)
    }

    /// still-image-time 元数据轨的格式描述 hint（metadata adaptor 必需）。
    private func stillImageTimeFormatHint() -> CMFormatDescription? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                "com.apple.metadata.datatype.int8"
        ]
        var hint: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &hint
        )
        LogStore.log("xdz.livephoto.exporter still-image-time hint status=\(status) ok=\(hint != nil)")
        return hint
    }

    /// 封面 JPEG：写入 EXIF MakerApple 的 AssetIdentifier（key "17"），与视频轨配对
    private func jpegData(from ci: CIImage, assetID: String) -> Data? {
        guard let image = context.createCGImage(ci, from: ci.extent) else {
            LogStore.log("xdz.livephoto.exporter create cover CGImage failed")
            return nil
        }
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  data, UTType.jpeg.identifier as CFString, 1, nil
              ) else {
            LogStore.log("xdz.livephoto.exporter create JPEG destination failed")
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyMakerAppleDictionary: ["17": assetID]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            LogStore.log("xdz.livephoto.exporter finalize cover JPEG failed")
            return nil
        }
        return data as Data
    }
}
