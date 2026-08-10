import CoreGraphics
import Foundation

// MARK: - 模板

/// 内置模板：纯代码定义，JSON 可序列化
public struct MagicTemplate: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var tagline: String
    /// SF Symbol，UI 展示用
    public var symbolName: String
    public var canvasPreset: CanvasSpec?
    public var background: BackgroundPreset?
    public var decorations: [DecorationPreset]
    public var effectPresets: [String]
    /// 人物元素默认摆放（按添加顺序）
    public var elementLayouts: [ElementLayoutPreset]

    public init(
        id: String,
        name: String,
        tagline: String,
        symbolName: String,
        canvasPreset: CanvasSpec? = nil,
        background: BackgroundPreset? = nil,
        decorations: [DecorationPreset] = [],
        effectPresets: [String] = [],
        elementLayouts: [ElementLayoutPreset] = []
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.symbolName = symbolName
        self.canvasPreset = canvasPreset
        self.background = background
        self.decorations = decorations
        self.effectPresets = effectPresets
        self.elementLayouts = elementLayouts
    }
}

/// 装饰摆放预设
public struct DecorationPreset: Codable, Equatable {
    public var decorationID: String
    public var transform: ElementTransform
    public var zIndex: Int

    public init(decorationID: String, transform: ElementTransform, zIndex: Int = 0) {
        self.decorationID = decorationID
        self.transform = transform
        self.zIndex = zIndex
    }
}

/// 人物元素布局预设
public struct ElementLayoutPreset: Codable, Equatable {
    public var transform: ElementTransform
    public var zIndex: Int

    public init(transform: ElementTransform, zIndex: Int = 0) {
        self.transform = transform
        self.zIndex = zIndex
    }
}
