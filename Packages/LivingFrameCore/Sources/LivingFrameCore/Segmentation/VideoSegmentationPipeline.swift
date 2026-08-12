import AVFoundation
import CoreImage
import Foundation

public enum SegmentationError: Error {
    case noVideoTrack
    case readerUnavailable
    case noFrames
    case cancelled
}

/// 视频抠图管线：逐帧读流 → 实例掩码抠图 → 透明 PNG 序列 → 提取音频
public struct VideoSegmentationPipeline {
    public struct ProgressInfo {
        public let fraction: Double
        public let frameIndex: Int
        public let totalFrames: Int
    }

    public typealias ProgressHandler = (ProgressInfo) -> Void

    /// preferredTransform → CGImagePropertyOrientation（0/90/180/270 + 镜像）
    static func orientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let mirrored = (transform.a * transform.d - transform.b * transform.c) < 0
        var degrees = (atan2(transform.b, transform.a) * 180 / .pi)
            .truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        switch Int(degrees.rounded()) {
        case 90: return mirrored ? .rightMirrored : .right
        case 180: return mirrored ? .downMirrored : .down
        case 270: return mirrored ? .leftMirrored : .left
        default: return mirrored ? .upMirrored : .up
        }
    }

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    public init() {}

    @discardableResult
    public func segmentVideo(
        at url: URL,
        name: String = NSLocalizedString("素材", comment: "Default clip name"),
        maxDimension: CGFloat = 1280,
        maxFPS: Double = 30,
        stillOrientation: CGImagePropertyOrientation = .up,
        progress: ProgressHandler? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) async throws -> SegmentedClip {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            LogStore.log("segmentVideo: no video track \(url.lastPathComponent)")
            throw SegmentationError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let frameRate = try await track.load(.nominalFrameRate)
        // AVAssetReader 输出的是未旋转的原始像素，需应用 preferredTransform 恢复拍摄方向
        let preferredTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        // 源帧率异常（0/NaN）时按 30fps 兜底，避免抽帧计算产生 NaN
        let safeFrameRate = frameRate.isFinite && frameRate > 0 ? Double(frameRate) : 30
        // 抽帧步长：目标帧率低于源帧率时，隔 N 帧处理 1 帧
        let frameStep = max(1, Int((safeFrameRate / maxFPS).rounded()))
        let outputFPS = max(1, safeFrameRate / Double(frameStep))
        LogStore.log("segmentVideo input: name=\(url.lastPathComponent) size=\(Int(naturalSize.width))x\(Int(naturalSize.height)) duration=\(duration.seconds)s fps=\(safeFrameRate) step=\(frameStep) outputFPS=\(outputFPS) transform=\(preferredTransform) stillOrientation=\(stillOrientation.rawValue) derivedOrientation=\(preferredTransform.isIdentity ? (stillOrientation == .down ? "down(180°)" : "none") : "\(Self.orientation(from: preferredTransform).rawValue)")" )

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SegmentationError.readerUnavailable }
        reader.add(output)
        guard reader.startReading() else { throw SegmentationError.readerUnavailable }

        let clipID = UUID().uuidString
        let folder = try FrameCache.shared.makeClipFolder(id: clipID)
        let totalFrames = max(1, Int((duration.seconds * outputFPS).rounded(.up)))

        let segmenter = VisionPersonSegmenter()
        var index = 0
        var sampleIndex = 0
        var firstSize: (width: Int, height: Int)?
        var skippedNoSubject = 0
        var skippedNoImage = 0
        /// 上一帧分割结果（时域补全用，只存原始帧避免累计拖影）
        var prevMaskedImage: CIImage?

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                LogStore.log("segmentVideo: user cancelled")
                throw SegmentationError.cancelled
            }
            let process = sampleIndex % frameStep == 0
            sampleIndex += 1
            guard process else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                skippedNoImage += 1
                continue
            }
            let source = CIImage(cvPixelBuffer: pixelBuffer)
            // 方向修正：优先用视频轨旋转元数据；若变换不含旋转（identity、仅平移或浮点误差导致
            // 推导为 up/down），则以静态图 EXIF 方向为准——Live Photo 的静态图与视频来自同一次
            // 拍摄，方向一致；普通视频不传 stillOrientation（.up）不受影响
            let derived = Self.orientation(from: preferredTransform)
            let oriented: CIImage
            if derived == .up || derived == .down {
                oriented = stillOrientation == .up
                    ? source
                    : source.oriented(stillOrientation)
            } else {
                oriented = source.oriented(derived)
            }
            LogStore.log("segmentVideo: frame \(index) derived=\(derived.rawValue) still=\(stillOrientation.rawValue) using=\(oriented.extent.width)x\(oriented.extent.height)")
            let scale = min(1.0, maxDimension / max(oriented.extent.width, oriented.extent.height))
            let input = scale < 1.0
                ? oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : oriented
            guard let cgImage = context.createCGImage(input, from: input.extent.integral) else { continue }

            do {
                let segmented = try segmenter.segmentedImage(from: cgImage)
                let current = CIImage(cgImage: segmented)
                // 时域补全：与上一帧原始分割结果做并集（通道取最大）。
                // 逐帧独立分割会偶发漏检（如腿部某帧缺失），并集让漏检帧用上一帧补全。
                // 只与上一帧并集，不累计，避免人物移动产生拖影。
                let output: CIImage
                if let prev = prevMaskedImage {
                    output = current.applyingFilter("CIMaximumCompositing", parameters: [
                        kCIInputBackgroundImageKey: prev
                    ])
                } else {
                    output = current
                }
                prevMaskedImage = current
                guard let outCG = context.createCGImage(output, from: output.extent.integral) else { continue }
                let frameURL = folder.appendingPathComponent(String(format: "%05d.png", index))
                guard writePNG(outCG, to: frameURL) else { continue }
                if firstSize == nil {
                    firstSize = (outCG.width, outCG.height)
                }
                index += 1
                progress?(ProgressInfo(
                    fraction: min(1, Double(index) / Double(totalFrames)),
                    frameIndex: index,
                    totalFrames: totalFrames
                ))
            } catch {
                // 帧内无人物（人物出画/遮挡），跳过该帧
                skippedNoSubject += 1
                continue
            }
        }

        reader.cancelReading()

        LogStore.log("segmentVideo output: okFrames=\(index) skippedNoSubject=\(skippedNoSubject) skippedNoImage=\(skippedNoImage) frameSize=\(firstSize?.width ?? 0)x\(firstSize?.height ?? 0)")

        guard index > 0, let firstSize else {
            LogStore.log("segmentVideo failed: 0 valid frames")
            throw SegmentationError.noFrames
        }

        var clip = SegmentedClip(
            id: clipID,
            name: name,
            fps: outputFPS,
            frameCount: index,
            width: firstSize.width,
            height: firstSize.height,
            folderURL: folder
        )

        // 提取音频（若有）
        let audioURL = folder.appendingPathComponent("audio.m4a")
        if try await AudioExtractor().extractAudio(from: url, to: audioURL) {
            clip.audioURL = audioURL
        }

        LogStore.log("segmentVideo done: clip=\(clipID) name=\(name) frames=\(clip.frameCount) fps=\(clip.fps) size=\(clip.width)x\(clip.height) duration=\(clip.duration)s audio=\(clip.audioURL != nil)")
        LogStore.trimIfNeeded()
        FrameCache.shared.register(clip)
        return clip
    }

    /// 单张照片抠图：实例掩码 → 透明 PNG → 生成 1 帧的素材
    public func segmentPhoto(
        from source: CGImage,
        name: String = NSLocalizedString("素材", comment: "Default clip name"),
        maxDimension: CGFloat = 1280
    ) throws -> SegmentedClip {
        let sourceImage = CIImage(cgImage: source)
        let scale = min(1.0, maxDimension / max(sourceImage.extent.width, sourceImage.extent.height))
        let input = scale < 1.0
            ? sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : sourceImage
        guard let cgImage = context.createCGImage(input, from: input.extent) else {
            throw SegmentationError.noFrames
        }
        let segmented = try VisionPersonSegmenter().segmentedImage(from: cgImage)

        let clipID = UUID().uuidString
        let folder = try FrameCache.shared.makeClipFolder(id: clipID)
        let frameURL = folder.appendingPathComponent("00000.png")
        guard writePNG(segmented, to: frameURL) else { throw SegmentationError.noFrames }

        let clip = SegmentedClip(
            id: clipID,
            name: name,
            fps: 1,
            frameCount: 1,
            width: segmented.width,
            height: segmented.height,
            folderURL: folder
        )
        LogStore.log("segmentPhoto done: clip=\(clipID) name=\(name) input=\(sourceImage.extent.width)x\(sourceImage.extent.height) output=\(segmented.width)x\(segmented.height)")
        LogStore.trimIfNeeded()
        FrameCache.shared.register(clip)
        return clip
    }
}
