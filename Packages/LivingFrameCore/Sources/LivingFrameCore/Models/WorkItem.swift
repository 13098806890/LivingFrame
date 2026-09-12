import CoreGraphics
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

/// 导出最长边预设。`original` 从不放大工程画布，其他档位只会按比例缩小。
public enum ExportResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case original
    case p480
    case p720
    case p1080

    public var id: String { rawValue }

    public var maxPixelSize: CGFloat? {
        switch self {
        case .original: nil
        case .p480: 480
        case .p720: 720
        case .p1080: 1080
        }
    }

    public var title: String {
        switch self {
        case .original: NSLocalizedString("原始", comment: "Export resolution")
        case .p480: "480p"
        case .p720: "720p"
        case .p1080: "1080p"
        }
    }

    public func outputSize(for source: CGSize, requiresEvenDimensions: Bool = false) -> CGSize {
        let longestEdge = max(source.width, source.height, 1)
        let scale = maxPixelSize.map { min($0 / longestEdge, 1) } ?? 1
        var width = max(Int((source.width * scale).rounded()), 1)
        var height = max(Int((source.height * scale).rounded()), 1)
        if requiresEvenDimensions {
            width = max(width - width % 2, 2)
            height = max(height - height % 2, 2)
        }
        return CGSize(width: width, height: height)
    }
}

/// 作品快照：可重新编辑、重导出
public struct WorkDraft: Codable, Equatable {
    /// 草稿最近一次自动保存时间；不影响正式作品的更新时间。
    public var updatedAt: Date
    /// 草稿工程快照。
    public var composition: Composition
    /// 草稿对应的素材级编辑设置。
    public var clipSettings: [WorkClipSettings]
    /// 草稿自己的封面。旧数据没有此字段时由正式封面兜底。
    public var posterData: Data?

    public init(
        updatedAt: Date = Date(),
        composition: Composition,
        clipSettings: [WorkClipSettings] = [],
        posterData: Data? = nil
    ) {
        self.updatedAt = updatedAt
        self.composition = composition
        self.clipSettings = clipSettings
        self.posterData = posterData
    }
}

/// 作品快照：可重新编辑、重导出。
/// 正式版本保留在 composition；编辑过程中的自动保存版本放在 draft 中。
public struct WorkItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// 最近一次主动保存时间。
    public var updatedAt: Date
    /// 完整工程快照
    public var composition: Composition
    /// 素材级编辑设置。
    public var clipSettings: [WorkClipSettings]
    /// 封面 PNG 数据
    public var posterData: Data
    public var format: ExportFormat
    /// 自动保存的未提交草稿；nil 表示当前作品没有草稿。
    public var draft: WorkDraft?
    /// 最近一次明确点击“保存”的时间。nil 表示只有自动保存草稿。
    /// 该字段为可选值，以兼容升级前已经写入磁盘的作品数据。
    public var savedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        composition: Composition,
        clipSettings: [WorkClipSettings] = [],
        posterData: Data,
        format: ExportFormat,
        draft: WorkDraft? = nil,
        savedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.composition = composition
        self.clipSettings = clipSettings
        self.posterData = posterData
        self.format = format
        self.draft = draft
        self.savedAt = savedAt
    }

    public var lastSavedAt: Date { updatedAt }

    /// 是否存在可展示在“已保存作品”中的正式版本。
    /// 旧数据没有 savedAt：无草稿的一定是正式作品；同时含草稿时，可用草稿时间
    /// 晚于正式更新时间这一旧保存规则恢复出“正式版本 + 后续草稿”的状态。
    public var hasSavedVersion: Bool {
        if savedAt != nil { return true }
        guard let draft else { return true }
        return draft.updatedAt > updatedAt
    }

    /// 草稿箱是全局入口，只展示最近更新的一份草稿。
    /// 旧版本可能已经把草稿写在多个作品上，因此启动和保存时都使用这个规则
    /// 清理较旧作品的 `draft` 字段；正式作品本身不会被删除或修改。
    public static func retainingOnlyLatestDraft(in works: [WorkItem]) -> [WorkItem] {
        var latestDraftID: UUID?
        var latestDraftDate: Date?

        for work in works {
            guard let draft = work.draft else { continue }
            if latestDraftDate == nil || draft.updatedAt >= latestDraftDate! {
                latestDraftID = work.id
                latestDraftDate = draft.updatedAt
            }
        }

        guard let latestDraftID else { return works }
        return works.map { work in
            guard work.id != latestDraftID, work.draft != nil else { return work }
            var cleaned = work
            cleaned.draft = nil
            return cleaned
        }
    }
}
