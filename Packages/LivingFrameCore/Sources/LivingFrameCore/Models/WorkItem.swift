import Foundation

/// 作品引用素材的可编辑设置快照。帧文件仍复用素材库，不重复占用磁盘。
public struct WorkClipSettings: Codable, Equatable {
    public var clipID: String
    public var edgeStyle: ClipEdgeStyle
    public var edgeLineStyle: EdgeLineStyle
    public var edgeThickness: EdgeThickness
    public var edgeColorHex: String
    public var stickerStyle: StickerStyle
    public var playbackSpeed: Double
    public var excludedFrames: Set<Int>

    public init(
        clipID: String,
        edgeStyle: ClipEdgeStyle,
        edgeLineStyle: EdgeLineStyle,
        edgeThickness: EdgeThickness,
        edgeColorHex: String,
        stickerStyle: StickerStyle,
        playbackSpeed: Double,
        excludedFrames: Set<Int>
    ) {
        self.clipID = clipID
        self.edgeStyle = edgeStyle
        self.edgeLineStyle = edgeLineStyle
        self.edgeThickness = edgeThickness
        self.edgeColorHex = edgeColorHex
        self.stickerStyle = stickerStyle
        self.playbackSpeed = playbackSpeed
        self.excludedFrames = excludedFrames
    }
}

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
    /// 最近一次主动保存时间；旧版本作品没有该字段时回退到 createdAt。
    public var updatedAt: Date?
    /// 完整工程快照
    public var composition: Composition
    /// 素材级编辑设置；旧作品为 nil，继续使用素材库当前设置。
    public var clipSettings: [WorkClipSettings]?
    /// 封面 PNG 数据
    public var posterData: Data
    public var format: ExportFormat

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        composition: Composition,
        clipSettings: [WorkClipSettings]? = nil,
        posterData: Data,
        format: ExportFormat
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.composition = composition
        self.clipSettings = clipSettings
        self.posterData = posterData
        self.format = format
    }

    public var lastSavedAt: Date { updatedAt ?? createdAt }
}
