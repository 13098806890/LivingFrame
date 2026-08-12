import CoreGraphics
import Foundation
import ImageIO

/// 抠图结果：透明 PNG 帧序列 + 可选音频，磁盘缓存
public struct SegmentedClip: Identifiable {
    public let id: String
    public let name: String
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

    public var duration: TimeInterval {
        fps > 0 ? TimeInterval(frameCount) / fps : 1
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
