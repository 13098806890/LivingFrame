import CoreGraphics
import Foundation

/// 画布比例预设
public enum CanvasAspect: String, CaseIterable, Identifiable {
    case portrait9x16
    case portrait4x5
    case portrait3x4
    case square1x1
    case landscape16x9

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .portrait9x16: NSLocalizedString("9:16 竖屏", comment: "Canvas aspect")
        case .portrait4x5: NSLocalizedString("4:5 竖屏", comment: "Canvas aspect")
        case .portrait3x4: NSLocalizedString("3:4 竖屏", comment: "Canvas aspect")
        case .square1x1: NSLocalizedString("1:1 方形", comment: "Canvas aspect")
        case .landscape16x9: NSLocalizedString("16:9 横屏", comment: "Canvas aspect")
        }
    }

    /// 画布尺寸（1080 基准）
    public var canvasSize: CGSize {
        switch self {
        case .portrait9x16: CGSize(width: 1080, height: 1920)
        case .portrait4x5: CGSize(width: 1080, height: 1350)
        case .portrait3x4: CGSize(width: 1080, height: 1440)
        case .square1x1: CGSize(width: 1080, height: 1080)
        case .landscape16x9: CGSize(width: 1920, height: 1080)
        }
    }

    /// 当前画布尺寸对应的比例
    public static func aspect(for size: CGSize) -> CanvasAspect {
        guard size.width > 0, size.height > 0 else { return .portrait9x16 }
        let ratio = size.width / size.height
        // 用实际预设比例取最近值，避免 3:4 和 4:5 的区间重叠时选错比例。
        return allCases.min {
            abs(ratio - $0.canvasSize.width / $0.canvasSize.height)
                < abs(ratio - $1.canvasSize.width / $1.canvasSize.height)
        } ?? .portrait9x16
    }
}
