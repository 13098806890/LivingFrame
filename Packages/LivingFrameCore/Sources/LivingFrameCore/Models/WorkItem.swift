import Foundation

/// 导出格式
public enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case gif
    case hevcAlpha
    case h264
    case livePhoto

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .gif: "gif"
        case .hevcAlpha, .h264, .livePhoto: "mov"
        }
    }

    public var title: String {
        switch self {
        case .gif: NSLocalizedString("GIF（通用）", comment: "Export format")
        case .hevcAlpha: NSLocalizedString("透明视频（HEVC-alpha）", comment: "Export format")
        case .h264: NSLocalizedString("普通视频（H.264）", comment: "Export format")
        case .livePhoto: NSLocalizedString("Live Photo（动态照片）", comment: "Export format")
        }
    }

    public var subtitle: String {
        switch self {
        case .gif: NSLocalizedString("兼容性最广，适合分享，透明边缘为硬边", comment: "Export format subtitle")
        case .hevcAlpha: NSLocalizedString("保留半透明边缘，体积小，适合再次合成", comment: "Export format subtitle")
        case .h264: NSLocalizedString("无透明通道，最通用的视频格式", comment: "Export format subtitle")
        case .livePhoto: NSLocalizedString("存入相册长按播放，透明区域用背景填充", comment: "Export format subtitle")
        }
    }
}

/// 作品快照：可重新编辑、重导出
public struct WorkItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// 完整工程快照
    public var composition: Composition
    /// 封面 PNG 数据
    public var posterData: Data
    public var format: ExportFormat

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        composition: Composition,
        posterData: Data,
        format: ExportFormat
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.composition = composition
        self.posterData = posterData
        self.format = format
    }
}
