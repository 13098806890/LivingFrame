import Foundation

/// 素材边缘效果（渲染时套在人物轮廓外）
public enum ClipEdgeStyle: String, Codable, CaseIterable, Identifiable {
    case none
    case whiteOutline
    case blackOutline
    case goldOutline
    case glow
    case shadow
    case comic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: NSLocalizedString("无", comment: "Edge style")
        case .whiteOutline: NSLocalizedString("白色描边", comment: "Edge style")
        case .blackOutline: NSLocalizedString("黑色描边", comment: "Edge style")
        case .goldOutline: NSLocalizedString("金色描边", comment: "Edge style")
        case .glow: NSLocalizedString("柔光", comment: "Edge style")
        case .shadow: NSLocalizedString("投影", comment: "Edge style")
        case .comic: NSLocalizedString("漫画描边", comment: "Edge style")
        }
    }
}
