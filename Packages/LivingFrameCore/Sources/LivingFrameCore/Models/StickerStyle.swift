import Foundation

/// 贴纸风格（参照 iOS 贴纸的 Outline、Comic 与柔化效果），与边缘效果可叠加。
public enum StickerStyle: String, Codable, CaseIterable, Identifiable {
    case none
    case outline
    case comic
    case smooth
    public var id: String { rawValue }

    /// 保留移除 customOutline 前已经保存的作品外观。旧值最接近普通描边，
    /// 不应在升级后静默变成无效果。
    public init?(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "outline": self = .outline
        case "comic": self = .comic
        case "smooth": self = .smooth
        case "customOutline": self = .outline
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .none: NSLocalizedString("无", comment: "Sticker style")
        case .outline: NSLocalizedString("描边", comment: "Sticker style")
        case .comic: NSLocalizedString("漫画", comment: "Sticker style")
        case .smooth: NSLocalizedString("平滑", comment: "Sticker style")
        }
    }

    /// 兼容旧版本已经保存的 customOutline 等值；未知值回退到原图。
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = StickerStyle(rawValue: rawValue) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
