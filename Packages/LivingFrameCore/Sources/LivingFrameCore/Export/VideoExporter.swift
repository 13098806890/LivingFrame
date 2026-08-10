import AVFoundation
import Foundation

/// 视频导出：HEVC-alpha（带透明，首选）/ H.264 回退，可混入音轨
public struct VideoExporter {
    public init() {}

    public func export(
        _ composition: Composition,
        format: ExportFormat,
        sourceResolver: @escaping (String) -> URL?,
        to url: URL,
        progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) async throws {
        let width = max(2, Int(composition.canvas.width))
        let height = max(2, Int(composition.canvas.height))
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let codec: AVVideoCodecType = format == .h264 ? .h264 : .hevcWithAlpha
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000
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

        // 音频轨（如需）
        let hasAudio = !composition.audioClips.isEmpty
        var audioInput: AVAssetWriterInput?
        if hasAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ])
            audio.expectsMediaDataInRealTime = false
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }
        }

        guard writer.startWriting() else { throw ExportError.renderFailed }
        writer.startSession(atSourceTime: .zero)

        // 1. 渲染视频帧
        let renderer = CompositionRenderer()
        let frameCount = max(1, Int(composition.duration * composition.fps))
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
            renderer.render(composition, at: Double(index) / composition.fps, into: buffer)
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(composition.fps))
            guard adaptor.append(buffer, withPresentationTime: time) else { throw ExportError.renderFailed }
            progress(Double(index + 1) / Double(frameCount + 1))
        }
        videoInput.markAsFinished()

        // 2. 离线混音并写入音频轨
        if let audioInput {
            let mixedURL = url.deletingPathExtension().appendingPathExtension("mix.m4a")
            do {
                try await OfflineAudioMixer().mix(
                    composition.audioClips,
                    duration: composition.duration,
                    sourceResolver: sourceResolver,
                    to: mixedURL
                )
                try await appendAudio(from: mixedURL, to: audioInput)
            } catch {
                // 音频失败不阻断视频导出
            }
            try? FileManager.default.removeItem(at: mixedURL)
            audioInput.markAsFinished()
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.renderFailed }
    }

    private func appendAudio(from url: URL, to input: AVAssetWriterInput) async throws {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }

        while let sample = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 3_000_000)
            }
            if !input.append(sample) { break }
        }
        reader.cancelReading()
    }
}
