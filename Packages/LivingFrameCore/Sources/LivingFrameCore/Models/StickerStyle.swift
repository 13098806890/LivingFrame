import Foundation

/// 贴纸风格（参照 iOS 贴纸 STKStickerEffect 效果），与边缘效果可叠加
public enum StickerStyle: String, Codable, CaseIterable, Identifiable {
    case none
    case outline
    case comic
    case smooth

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: NSLocalizedString("无", comment: "Sticker style")
        case .outline: NSLocalizedString("描边", comment: "Sticker style")
        case .comic: NSLocalizedString("漫画", comment: "Sticker style")
        case .smooth: NSLocalizedString("平滑", comment: "Sticker style")
        }
    }
}
