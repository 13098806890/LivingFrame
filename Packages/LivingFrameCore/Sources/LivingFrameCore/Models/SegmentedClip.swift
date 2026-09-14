import CoreGraphics
import Foundation
import ImageIO

/// 抠图结果：透明 PNG 帧序列 + 可选音频，磁盘缓存
public struct SegmentedClip: Identifiable {
    public let id: String
    public var name: String
    public let fps: Double
    public let frameCount: Int
    public let width: Int
    public let height: Int
    /// 创建时间（持久化恢复时用于排序）
    public var createdAt: Date = Date()
    /// PNG 帧序列目录（00000.png, 00001.png ...）
    public let folderURL: URL
    /// 提取出的 m4a 音频（无音频轨时为 nil）
    public var audioURL: URL?
    /// 边缘效果（渲染时应用）
    public var edgeStyle: ClipEdgeStyle = .none
    /// 描边线条样式
    public var edgeLineStyle: EdgeLineStyle = .solid
    /// 描边粗细
    public var edgeThickness: EdgeThickness = .medium
    /// 描边颜色（hex）
    public var edgeColorHex: String = "FFFFFF"
    /// 贴纸风格（渲染时应用）
    public var stickerStyle: StickerStyle = .none
    /// 播放倍速（1 = 正常；>1 快放，<1 慢放）
    public var playbackSpeed: Double = 1
    /// 被排除的帧索引（播放时由前面最近的保留帧填补，用于"帧选择"功能）
    public var excludedFrames: Set<Int> = []
    /// 用户在素材详情页主动旋转的次数；每次为顺时针 90°。
    public var rotationQuarterTurns: Int = 0
    /// 素材裁剪区域，使用当前旋转后画面的归一化坐标（原点在左下角）。nil 表示完整素材。
    public var cropRect: CGRect?

    public var normalizedRotationQuarterTurns: Int {
        ((rotationQuarterTurns % 4) + 4) % 4
    }

    /// 保留累计次数，让界面动画可以连续经过 360°，而不是从 270° 跳回 0°。
    public mutating func rotateClockwiseQuarterTurn() {
        if let cropRect {
            self.cropRect = CGRect(
                x: cropRect.minY,
                y: 1 - cropRect.maxX,
                width: cropRect.height,
                height: cropRect.width
            )
        }
        rotationQuarterTurns += 1
    }

    public var orientedWidth: Int {
        normalizedRotationQuarterTurns % 2 == 1 ? height : width
    }

    public var orientedHeight: Int {
        normalizedRotationQuarterTurns % 2 == 1 ? width : height
    }

    public var normalizedCropRect: CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let cropRect,
              cropRect.minX.isFinite, cropRect.minY.isFinite,
              cropRect.width.isFinite, cropRect.height.isFinite,
              cropRect.width > 0, cropRect.height > 0 else {
            return unit
        }
        let minX = min(max(cropRect.minX, 0), 1)
        let minY = min(max(cropRect.minY, 0), 1)
        let maxX = min(max(cropRect.maxX, 0), 1)
        let maxY = min(max(cropRect.maxY, 0), 1)
        guard maxX > minX, maxY > minY else { return unit }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var renderedWidth: Int {
        max(Int((CGFloat(orientedWidth) * normalizedCropRect.width).rounded()), 1)
    }

    public var renderedHeight: Int {
        max(Int((CGFloat(orientedHeight) * normalizedCropRect.height).rounded()), 1)
    }

    public var cropCacheKey: String {
        let rect = normalizedCropRect
        return "crop\(Int((rect.minX * 100_000).rounded()))-\(Int((rect.minY * 100_000).rounded()))-\(Int((rect.width * 100_000).rounded()))-\(Int((rect.height * 100_000).rounded()))"
    }

    /// Converts the oriented crop rectangle into the unrotated source image's coordinates.
    public var rawCropRect: CGRect {
        let rect = normalizedCropRect
        switch normalizedRotationQuarterTurns {
        case 1:
            return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        case 2:
            return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 3:
            return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }

    public mutating func setCropRect(_ rect: CGRect?) {
        guard let rect else {
            cropRect = nil
            return
        }
        let normalized = CGRect(
            x: min(max(rect.minX, 0), 1),
            y: min(max(rect.minY, 0), 1),
            width: min(max(rect.width, 0), 1),
            height: min(max(rect.height, 0), 1)
        )
        cropRect = normalized == CGRect(x: 0, y: 0, width: 1, height: 1) ? nil : normalized
    }

    public var duration: TimeInterval {
        fps > 0 ? TimeInterval(frameCount) / fps : 1
    }

    /// 素材在时间轴上的有效时长（按倍速折算）：
    /// 1x 就是自身时长，2x 只占一半时间，0.5x 占两倍时间
    public var effectiveDuration: TimeInterval {
        activeDuration / max(playbackSpeed, 0.01)
    }

    /// 参与播放的帧索引（升序，排除 excludedFrames 后）
    public var activeFrameIndices: [Int] {
        let active = (0..<frameCount).filter { !excludedFrames.contains($0) }
        return active.isEmpty ? Array(0..<frameCount) : active
    }

    /// 正放时使用的等长播放映射。
    public var playbackFrameIndices: [Int] {
        playbackFrameIndices(reversed: false)
    }

    /// 与原始帧序列等长的播放映射。排除某帧时，使用播放方向上刚显示过的保留帧填补；
    /// 例如排除第 4 帧得到 1,2,3,3,5，排除第 3、4 帧得到 1,2,2,2,5。
    /// 正放开头或倒放结尾没有上一帧可用时，使用另一侧第一张保留帧兜底。
    public func playbackFrameIndices(reversed: Bool) -> [Int] {
        guard frameCount > 0 else { return [] }
        let kept = (0..<frameCount).filter { !excludedFrames.contains($0) }
        // 全部排除属于无效选择，回退到原始序列，避免素材只剩空画面。
        guard let firstKept = kept.first else { return Array(0..<frameCount) }

        if reversed {
            var nextKept = kept.last ?? firstKept
            var result = Array(repeating: nextKept, count: frameCount)
            for index in stride(from: frameCount - 1, through: 0, by: -1) {
                if !excludedFrames.contains(index) {
                    nextKept = index
                }
                result[index] = nextKept
            }
            return result
        }

        var lastKept = firstKept
        return (0..<frameCount).map { index in
            if !excludedFrames.contains(index) {
                lastKept = index
            }
            return lastKept
        }
    }

    /// 排除帧只改变对应时刻显示的画面，不压缩素材，播放时长始终保持不变。
    public var activeDuration: TimeInterval {
        fps > 0 ? TimeInterval(playbackFrameIndices.count) / fps : 1
    }

    public func frameURL(index: Int) -> URL {
        folderURL.appendingPathComponent(String(format: "%05d.png", index))
    }

    public func loadFrame(index: Int) -> CGImage? {
        let clamped = min(max(index, 0), frameCount - 1)
        let url = frameURL(index: clamped) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 加载音频文件 URL（校验存在性）
    public func loadAudioURL() -> URL? {
        guard let audioURL, FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        return audioURL
    }
}
