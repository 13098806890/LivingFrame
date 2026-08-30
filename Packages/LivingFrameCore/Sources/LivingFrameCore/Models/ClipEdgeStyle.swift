import Foundation

/// 描边线条样式
public enum EdgeLineStyle: String, Codable, CaseIterable, Identifiable {
    case solid
    case dashed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .solid: NSLocalizedString("实线", comment: "Edge line style")
        case .dashed: NSLocalizedString("线段", comment: "Edge line style")
        }
    }
}

/// 描边粗细
public enum EdgeThickness: String, Codable, CaseIterable, Identifiable {
    case thin
    case medium
    case thick

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thin: NSLocalizedString("细", comment: "Edge thickness")
        case .medium: NSLocalizedString("中", comment: "Edge thickness")
        case .thick: NSLocalizedString("粗", comment: "Edge thickness")
        }
    }

    /// 描边半径（像素）
    public var radius: CGFloat {
        switch self {
        case .thin: 18
        case .medium: 36
        case .thick: 60
        }
    }
}

/// 素材边缘效果（渲染时套在人物轮廓外）
/// 描边为组合式：线条样式 × 粗细 × 颜色（分别存在 SegmentedClip 上）
public enum ClipEdgeStyle: String, Codable, CaseIterable, Identifiable {
    case none
    case outline
    case glow
    case shadow
    case comic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: NSLocalizedString("无", comment: "Edge style")
        case .outline: NSLocalizedString("描边", comment: "Edge style")
        case .glow: NSLocalizedString("柔光", comment: "Edge style")
        case .shadow: NSLocalizedString("投影", comment: "Edge style")
        case .comic: NSLocalizedString("漫画", comment: "Edge style")
        }
    }

    /// 是否描边类（跟随组合描边设置）
    public var isOutline: Bool {
        switch self {
        case .outline: return true
        case .none, .glow, .shadow, .comic: return false
        }
    }

    public static let displayCases: [ClipEdgeStyle] = [.none, .outline, .comic]
}
