import AVFoundation
import CoreImage
import Foundation
@preconcurrency import Dispatch

private final class ExportSessionBox: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else { return false }
        didComplete = true
        return true
    }
}

private enum RemuxWaitResult {
    case completed
    case timedOut
}

/// 视频导出：HEVC-alpha（带透明，首选）/ H.264 回退，可混入音轨
///
/// 实现：AVAssetWriter 只写视频轨（单输入），音频用 OfflineAudioMixer 混音后，
/// 经 AVMutableComposition + AVAssetExportSession(passthrough) 合并。
/// 原因：多输入 writer（video+audio）在本机实测会触发 VideoToolbox 假死
/// （isReadyForMoreMediaData 永久 false，status 保持 .writing，卡点随机），
/// 而单视频轨写入稳定且 remux(passthrough) 已验证保留 HEVC-alpha 透明通道。
public struct VideoExporter {
    public init() {}

    public func export(
        _ composition: Composition,
        format: ExportFormat,
        sourceResolver: @escaping (String) -> URL?,
        to url: URL,
        fps: Double? = nil,
        maxPixelSize: CGFloat? = nil,
        progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) async throws {
        let renderSize = outputSize(for: composition.renderRect.size, maxPixelSize: maxPixelSize)
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        try? FileManager.default.removeItem(at: url)
        let start = Date()
        let exportFPS = fps.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? composition.fps
        let frameCount = max(1, Int((composition.duration * exportFPS).rounded(.up)))
        let hasAudio = !composition.audioClips.isEmpty
        LogStore.log("VideoExporter: start codec=\(format.rawValue) size=\(width)x\(height) frames=\(frameCount) audio=\(hasAudio) url=\(url.path)")

        // 1. 视频轨（进度 0~0.95）
        try await writeVideoTrack(
            composition, format: format, to: url,
            fps: exportFPS, frameCount: frameCount, renderSize: renderSize,
            progress: progress, isCancelled: isCancelled
        )
        LogStore.log("VideoExporter: video track done elapsed=\(Int(Date().timeIntervalSince(start)))s")

        // 2. 混音 + 合并音轨（进度 0.95~1.0），失败不阻断视频导出
        if hasAudio {
            let mixedURL = url.deletingPathExtension().appendingPathExtension("mix.m4a")
            do {
                progress(0.95)
                LogStore.log("VideoExporter: start audio mix")
                try await OfflineAudioMixer().mix(
                    composition.audioClips,
                    duration: composition.duration,
                    sourceResolver: sourceResolver,
                    to: mixedURL
                )
                LogStore.log("VideoExporter: audio mix done, remuxing")
                try await remux(videoURL: url, audioURL: mixedURL, to: url)
                LogStore.log("VideoExporter: remux done")
            } catch {
                // 音频失败不阻断视频导出
                LogStore.log("VideoExporter: audio mix/remux failed (keeping silent video) error=\(error)")
            }
            try? FileManager.default.removeItem(at: mixedURL)
        }
        progress(1.0)

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log("VideoExporter: done elapsed=\(Int(Date().timeIntervalSince(start)))s size=\(size) bytes")
        logAlphaStatus(of: url, tag: "VideoExporter")
    }

    // MARK: - 视频轨

    private func writeVideoTrack(
        _ composition: Composition,
        format: ExportFormat,
        to url: URL,
        fps: Double,
        frameCount: Int,
        renderSize: CGSize,
        progress: @escaping (Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws {
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        let start = Date()

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let codec: AVVideoCodecType = format == .h264 ? .h264 : .hevcWithAlpha
        // HEVC-alpha 通过 codec 本身启用透明编码；不要传入 muxa 不支持的
        // VideoToolbox compression properties（会在 input 初始化时抛 NSException）。
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: recommendedBitRate(
                width: width,
                height: height,
                fps: fps,
                format: format
            )
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            LogStore.log("VideoExporter: unsupported output settings codec=\(codec.rawValue) size=\(width)x\(height)")
            throw ExportError.renderFailed
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = 600
        guard writer.canAdd(videoInput) else { throw ExportError.renderFailed }
        writer.add(videoInput)

        // 像素池负责 BGRA 格式和尺寸，alpha 模式通过帧级 attachment 指定。
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.startWriting() else {
            LogStore.log("VideoExporter: startWriting failed status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
            throw ExportError.renderFailed
        }
        writer.startSession(atSourceTime: .zero)

        // 导出用软件渲染，避免 CIContext GPU 工作与 VideoToolbox 编码器争用导致 writer 卡死
        let renderContext = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .useSoftwareRenderer: true,
            .cacheIntermediates: false
        ])
        let renderer = CompositionRenderer(context: renderContext)
        defer {
            renderContext.clearCaches()
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolFlush(pool, .excessBuffers)
            }
        }
        var memory = ExportMemoryDiagnostics(exporter: "Video-\(format.rawValue)", frameCount: frameCount)
        memory.log("start-video-track")
        for index in 0..<frameCount {
            let stallStart = Date()
            var lastStallLog = Date()
            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    LogStore.log("VideoExporter: writer failed mid-way index=\(index)/\(frameCount) error=\(String(describing: writer.error))")
                    throw ExportError.renderFailed
                }
                if Date().timeIntervalSince(stallStart) > 15 {
                    LogStore.log("VideoExporter: ❌ writer stalled 15s, aborting index=\(index)/\(frameCount) status=\(writer.status.rawValue)")
                    videoInput.markAsFinished()
                    await writer.finishWriting()
                    throw ExportError.renderFailed
                }
                if Date().timeIntervalSince(lastStallLog) > 5 {
                    LogStore.log("VideoExporter: ⚠️ isReadyForMoreMediaData waiting > 5s index=\(index) status=\(writer.status.rawValue)")
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
            let renderStart = Date()
            let renderOK = try autoreleasepool { () throws -> Bool in
                guard let pool = adaptor.pixelBufferPool else {
                    LogStore.log("VideoExporter: pixelBufferPool is nil index=\(index) status=\(writer.status.rawValue)")
                    throw ExportError.renderFailed
                }
                var pixelBuffer: CVPixelBuffer?
                let createStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard createStatus == kCVReturnSuccess, let buffer = pixelBuffer else {
                    LogStore.log("VideoExporter: pixel buffer allocation failed index=\(index) status=\(createStatus)")
                    throw ExportError.renderFailed
                }
                if format == .hevcAlpha {
                    prepareAlphaPixelBuffer(buffer)
                }
                let rendered = renderer.render(
                    composition,
                    at: Double(index) / fps,
                    into: buffer,
                    outputSize: renderSize
                )
                let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    LogStore.log("VideoExporter: append failed index=\(index)/\(frameCount) status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
                    throw ExportError.renderFailed
                }
                pixelBuffer = nil
                return rendered
            }
            if !renderOK && index < 3 {
                LogStore.log("VideoExporter: render(into:) 失败 index=\(index)")
            }
            let renderCost = Date().timeIntervalSince(renderStart)
            if renderCost > 2 {
                LogStore.log("VideoExporter: ⚠️ frame \(index) render slow cost=\(Int(renderCost))s")
            }
            if (index + 1).isMultiple(of: 10) {
                renderContext.clearCaches()
            }
            if shouldLogMemory {
                memory.log("after-append", frame: index + 1, totalFrames: frameCount)
            }
            let fraction = Double(index + 1) / Double(frameCount) * 0.95
            if index % 20 == 0 || index == frameCount - 1 {
                LogStore.log("VideoExporter: video frame \(index + 1)/\(frameCount) elapsed=\(Int(Date().timeIntervalSince(start)))s")
            }
            progress(fraction)
        }
        memory.log("before-finish-writing")
        videoInput.markAsFinished()

        await writer.finishWriting()
        memory.log("after-finish-writing")
        guard writer.status == .completed else {
            LogStore.log("VideoExporter: finishWriting failed status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
            throw ExportError.renderFailed
        }
    }

    private func outputSize(for source: CGSize, maxPixelSize: CGFloat?) -> CGSize {
        let longest = max(source.width, source.height, 1)
        let scale = maxPixelSize.map { min($0 / longest, 1) } ?? 1
        let width = max(Int((source.width * scale).rounded()) / 2 * 2, 2)
        let height = max(Int((source.height * scale).rounded()) / 2 * 2, 2)
        return CGSize(width: width, height: height)
    }

    /// 分辨率和帧率降低时，同步降低码率，避免低清预设反而生成异常大的文件。
    private func recommendedBitRate(width: Int, height: Int, fps: Double, format: ExportFormat) -> Int {
        let bitsPerPixel = format == .hevcAlpha ? 0.16 : 0.12
        let calculated = Double(width * height) * max(fps, 1) * bitsPerPixel
        return min(max(Int(calculated.rounded()), 1_500_000), 12_000_000)
    }

    /// Clears a newly allocated destination buffer and marks its alpha mode.
    /// A pool is allowed to recycle memory; without this, transparent pixels can
    /// retain opaque/black bytes from a previous frame on some devices.
    private func prepareAlphaPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
            memset(baseAddress, 0, byteCount)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferAlphaChannelModeKey,
            kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
            .shouldPropagate
        )
    }

    // MARK: - 音视频合并

    /// 将纯视频轨与混音文件合并为最终视频（passthrough 不重编码，保留 alpha 通道）
    private func remux(videoURL: URL, audioURL: URL, to outputURL: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let targetVideo = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ExportError.renderFailed
        }
        let duration = try await videoAsset.load(.duration)
        let videoRange = CMTimeRange(start: .zero, duration: duration)
        try targetVideo.insertTimeRange(videoRange, of: videoTrack, at: .zero)

        let audioAsset = AVURLAsset(url: audioURL)
        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let targetAudio = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? targetAudio.insertTimeRange(videoRange, of: audioTrack, at: .zero)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.renderFailed
        }
        let tempURL = outputURL.deletingPathExtension().appendingPathExtension("remux.mov")
        try? FileManager.default.removeItem(at: tempURL)
        session.outputURL = tempURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false

        let sessionBox = ExportSessionBox(session)
        let result: RemuxWaitResult = await withCheckedContinuation { continuation in
            let gate = CompletionGate()
            let timeoutTask = Task { [sessionBox, gate] in
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
                guard gate.take() else { return }
                sessionBox.value.cancelExport()
                continuation.resume(returning: .timedOut)
            }

            sessionBox.value.exportAsynchronously {
                timeoutTask.cancel()
                guard gate.take() else { return }
                continuation.resume(returning: .completed)
            }
        }
        switch result {
        case .timedOut:
            throw ExportError.renderFailed
        case .completed:
            switch sessionBox.value.status {
            case .completed:
                break
            case .cancelled:
                throw CancellationError()
            default:
                LogStore.log("VideoExporter: remux failed status=\(sessionBox.value.status.rawValue) error=\(String(describing: sessionBox.value.error))")
                throw ExportError.renderFailed
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
    }

    // MARK: - 校验

    /// 读回导出文件，记录视频轨是否带 alpha 通道
    private func logAlphaStatus(of url: URL, tag: String) {
        Task {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            var codes: [String] = []
            var alphaModes: [String] = []
            let formatDescriptions = (try? await track.load(.formatDescriptions)) ?? []
            for formatDescription in formatDescriptions {
                let desc = formatDescription
                codes.append(fourCC(CMFormatDescriptionGetMediaSubType(desc)))
                let alpha = CMFormatDescriptionGetExtension(
                    desc, extensionKey: kCMFormatDescriptionExtension_AlphaChannelMode as CFString
                )
                alphaModes.append(String(describing: alpha))
            }
            LogStore.log("\(tag): alpha check subtype=\(codes.joined(separator: ",")) alphaMode=\(alphaModes.joined(separator: ","))")
        }
    }

    private func fourCC(_ code: FourCharCode) -> String {
        String(format: "%c%c%c%c",
               Int((code >> 24) & 0xFF), Int((code >> 16) & 0xFF),
               Int((code >> 8) & 0xFF), Int(code & 0xFF))
    }
}
