import Foundation

/// 贴纸风格（参照 iOS 贴纸 STKStickerEffect 效果），与边缘效果可叠加
/// 描边 = 固定白描边（iOS 贴纸风格）；自定义描边 = 线型×粗细×颜色参数可调
public enum StickerStyle: String, Codable, CaseIterable, Identifiable {
    case none
    case outline
    case customOutline
    case comic
    case smooth
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: NSLocalizedString("无", comment: "Sticker style")
        case .outline: NSLocalizedString("描边", comment: "Sticker style")
        case .customOutline: NSLocalizedString("自定义描边", comment: "Sticker style")
        case .comic: NSLocalizedString("漫画", comment: "Sticker style")
        case .smooth: NSLocalizedString("平滑", comment: "Sticker style")
        }
    }
}
