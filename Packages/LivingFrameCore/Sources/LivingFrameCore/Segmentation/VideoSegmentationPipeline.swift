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
        stillOrientation: CGImagePropertyOrientation = .up,
        progress: ProgressHandler? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) async throws -> SegmentedClip {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            LogStore.log("segmentVideo: 无视频轨 \(url.lastPathComponent)")
            throw SegmentationError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let frameRate = try await track.load(.nominalFrameRate)
        // AVAssetReader 输出的是未旋转的原始像素，需应用 preferredTransform 恢复拍摄方向
        let preferredTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        LogStore.log("segmentVideo 输入: name=\(url.lastPathComponent) size=\(Int(naturalSize.width))x\(Int(naturalSize.height)) duration=\(duration.seconds)s fps=\(frameRate) transform=\(preferredTransform) stillOrientation=\(stillOrientation.rawValue) 推导方向=\(preferredTransform.isIdentity ? (stillOrientation == .down ? "down(180°)" : "无") : "\(Self.orientation(from: preferredTransform).rawValue)")" )

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
        let totalFrames = max(1, Int((duration.seconds * Double(frameRate)).rounded(.up)))

        let segmenter = VisionPersonSegmenter()
        var index = 0
        var firstSize: (width: Int, height: Int)?
        var skippedNoSubject = 0
        var skippedNoImage = 0

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                LogStore.log("segmentVideo: 用户取消")
                throw SegmentationError.cancelled
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                skippedNoImage += 1
                continue
            }
            let source = CIImage(cvPixelBuffer: pixelBuffer)
            // 方向修正：视频带旋转元数据 → 转换为 CI 原生方向（oriented 内部处理坐标系）；
            // 无旋转元数据 → 仅当静态图 EXIF 为 180° 时修正（90°/270° 的照片方向不能代表视频像素）
            let oriented: CIImage
            if preferredTransform.isIdentity {
                oriented = stillOrientation == .down
                    ? source.oriented(.down)
                    : source
            } else {
                oriented = source.oriented(Self.orientation(from: preferredTransform))
            }
            let scale = min(1.0, maxDimension / max(oriented.extent.width, oriented.extent.height))
            let input = scale < 1.0
                ? oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : oriented
            guard let cgImage = context.createCGImage(input, from: input.extent.integral) else { continue }

            do {
                let segmented = try segmenter.segmentedImage(from: cgImage)
                let frameURL = folder.appendingPathComponent(String(format: "%05d.png", index))
                guard writePNG(segmented, to: frameURL) else { continue }
                if firstSize == nil {
                    firstSize = (segmented.width, segmented.height)
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

        LogStore.log("segmentVideo 输出: 成功帧=\(index) 无人物跳过=\(skippedNoSubject) 无图像跳过=\(skippedNoImage) 帧尺寸=\(firstSize?.width ?? 0)x\(firstSize?.height ?? 0)")

        guard index > 0, let firstSize else {
            LogStore.log("segmentVideo 失败: 有效帧为 0")
            throw SegmentationError.noFrames
        }

        var clip = SegmentedClip(
            id: clipID,
            name: name,
            fps: Double(frameRate),
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

        LogStore.log("segmentVideo 完成: clip=\(clipID) name=\(name) frames=\(clip.frameCount) fps=\(clip.fps) size=\(clip.width)x\(clip.height) duration=\(clip.duration)s audio=\(clip.audioURL != nil)")
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
        LogStore.log("segmentPhoto 完成: clip=\(clipID) name=\(name) 输入=\(sourceImage.extent.width)x\(sourceImage.extent.height) 输出=\(segmented.width)x\(segmented.height)")
        LogStore.trimIfNeeded()
        FrameCache.shared.register(clip)
        return clip
    }
}
