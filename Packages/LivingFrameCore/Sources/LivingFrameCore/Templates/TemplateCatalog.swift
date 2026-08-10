import CoreGraphics
import Foundation

/// 内置模板注册表（纯代码定义，离线可用）
public struct TemplateCatalog {
    public static let shared = TemplateCatalog()

    public let templates: [MagicTemplate]

    public func template(id: String) -> MagicTemplate? {
        templates.first { $0.id == id }
    }

    private init() {
        templates = [
            Self.frameTemplate,
            Self.cornersTemplate,
            Self.wandTemplate,
            Self.minimalTemplate
        ]
    }

    /// 魔法画框：深色渐变 + 金色画框，人物居中
    private static let frameTemplate = MagicTemplate(
        id: "frame",
        name: NSLocalizedString("魔法画框", comment: "Template name"),
        tagline: NSLocalizedString("金色画框 + 深邃背景", comment: "Template tagline"),
        symbolName: "rectangle.badge.plus",
        canvasPreset: CanvasSpec(width: 1080, height: 1440),
        background: .dark,
        decorations: [
            DecorationPreset(
                decorationID: "frame-gold",
                transform: ElementTransform(
                    position: CGPoint(x: 540, y: 720), scale: 1.06, rotation: 0
                ),
                zIndex: 90
            ),
            DecorationPreset(
                decorationID: "vignette",
                transform: ElementTransform(
                    position: CGPoint(x: 540, y: 720), scale: 1.02, rotation: 0
                ),
                zIndex: 85
            )
        ],
        effectPresets: ["glow-soft"],
        elementLayouts: [
            ElementLayoutPreset(
                transform: ElementTransform(
                    position: CGPoint(x: 540, y: 790), scale: 0.72, rotation: 0
                ),
                zIndex: 10
            )
        ]
    )

    /// 金色四角：杂志海报风
    private static let cornersTemplate = MagicTemplate(
        id: "corners",
        name: NSLocalizedString("金角海报", comment: "Template name"),
        tagline: NSLocalizedString("四角金饰 + 电影海报感", comment: "Template tagline"),
        symbolName: "rectangle.inset.filled",
        canvasPreset: CanvasSpec(width: 1080, height: 1080),
        background: BackgroundPreset(kind: .gradient, topColor: "2A1E10", bottomColor: "0D0A05"),
        decorations: [
            DecorationPreset(
                decorationID: "corners",
                transform: ElementTransform(position: CGPoint(x: 540, y: 540), scale: 1, rotation: 0),
                zIndex: 90
            )
        ],
        effectPresets: [],
        elementLayouts: [
            ElementLayoutPreset(
                transform: ElementTransform(position: CGPoint(x: 540, y: 560), scale: 0.82, rotation: 0),
                zIndex: 10
            )
        ]
    )

    /// 魔杖辉光：暗色 + 光束 + 星芒
    private static let wandTemplate = MagicTemplate(
        id: "wand",
        name: NSLocalizedString("魔杖辉光", comment: "Template name"),
        tagline: NSLocalizedString("光束 + 星芒光效", comment: "Template tagline"),
        symbolName: "sparkles",
        canvasPreset: CanvasSpec(width: 1080, height: 1440),
        background: BackgroundPreset(kind: .gradient, topColor: "14102A", bottomColor: "05050A"),
        decorations: [
            DecorationPreset(
                decorationID: "wand-beam",
                transform: ElementTransform(position: CGPoint(x: 540, y: 720), scale: 1, rotation: 0),
                zIndex: 80
            ),
            DecorationPreset(
                decorationID: "dust",
                transform: ElementTransform(position: CGPoint(x: 540, y: 720), scale: 1, rotation: 0),
                zIndex: 75
            )
        ],
        effectPresets: ["glow-orb"],
        elementLayouts: [
            ElementLayoutPreset(
                transform: ElementTransform(position: CGPoint(x: 540, y: 760), scale: 0.78, rotation: 0),
                zIndex: 10
            )
        ]
    )

    /// 纯净：黑底，无装饰，最简
    private static let minimalTemplate = MagicTemplate(
        id: "minimal",
        name: NSLocalizedString("纯净黑幕", comment: "Template name"),
        tagline: NSLocalizedString("极简，人物突出", comment: "Template tagline"),
        symbolName: "circle",
        canvasPreset: CanvasSpec(width: 1080, height: 1080),
        background: BackgroundPreset(kind: .solid, topColor: "000000", bottomColor: "000000"),
        decorations: [],
        effectPresets: [],
        elementLayouts: [
            ElementLayoutPreset(
                transform: ElementTransform(position: CGPoint(x: 540, y: 540), scale: 0.9, rotation: 0),
                zIndex: 10
            )
        ]
    )
}
