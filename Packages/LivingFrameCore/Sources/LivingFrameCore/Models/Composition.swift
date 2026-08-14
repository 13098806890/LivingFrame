import CoreGraphics
import Foundation

// MARK: - Canvas

public struct CanvasSpec: Codable, Equatable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }
}

// MARK: - Transform

public struct ElementTransform: Codable, Equatable {
    /// 元素中心点，画布坐标系（原点左下，y 向上）
    public var position: CGPoint
    /// 相对素材原始尺寸的缩放
    public var scale: CGFloat
    /// 弧度
    public var rotation: CGFloat

    public init(position: CGPoint = .zero, scale: CGFloat = 1, rotation: CGFloat = 0) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
    }
}

// MARK: - Element

public enum ElementKind: Codable, Equatable {
    case clip(clipID: String)
    case decoration(decorationID: String)
    case effect(effectID: String)
    case text(textID: String)
}

/// 文字元素（画布上的文字，渲染为透明底图片后走通用变换）
public struct TextElement: Identifiable, Codable, Equatable {
    public var id: UUID
    public var text: String
    /// 字号（画布坐标单位）
    public var fontSize: CGFloat
    /// 颜色 hex
    public var colorHex: String
    /// 字体名称（nil = 系统默认）
    public var fontName: String?

    public init(
        id: UUID = UUID(),
        text: String = "双击编辑文字",
        fontSize: CGFloat = 96,
        colorHex: String = "FFFFFF",
        fontName: String? = nil
    ) {
        self.id = id
        self.text = text
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.fontName = fontName
    }
}

/// 元素滤镜（CIFilter 预设，作用于元素内容）
public enum ElementFilter: String, Codable, Equatable, CaseIterable, Identifiable {
    case none
    case mono
    case warm
    case cool
    case retro

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: NSLocalizedString("原图", comment: "Element filter")
        case .mono: NSLocalizedString("黑白", comment: "Element filter")
        case .warm: NSLocalizedString("暖色", comment: "Element filter")
        case .cool: NSLocalizedString("冷色", comment: "Element filter")
        case .retro: NSLocalizedString("复古", comment: "Element filter")
        }
    }

    /// 对应 CIFilter 名（none 不应用）
    public var filterName: String? {
        switch self {
        case .none: nil
        case .mono: "CIPhotoEffectMono"
        case .warm: "CIPhotoEffectTransfer"
        case .cool: "CIPhotoEffectProcess"
        case .retro: "CIPhotoEffectInstant"
        }
    }
}

public struct CompositionElement: Identifiable, Codable, Equatable {
    public var id: UUID
    public var kind: ElementKind
    public var name: String
    public var transform: ElementTransform
    /// 层级，大者在上
    public var zIndex: Int
    /// 时间轴出现/消失（秒）
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    /// 元素级背景图案（垫在元素内容下层，nil = 无）
    public var backgroundPattern: BackgroundPatternStyle?
    /// 滤镜（作用于元素内容，nil = 原图）
    public var filter: ElementFilter?

    public init(
        id: UUID = UUID(),
        kind: ElementKind,
        name: String,
        transform: ElementTransform = ElementTransform(),
        zIndex: Int = 0,
        startTime: TimeInterval = 0,
        endTime: TimeInterval = .greatestFiniteMagnitude,
        backgroundPattern: BackgroundPatternStyle? = nil,
        filter: ElementFilter? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.transform = transform
        self.zIndex = zIndex
        self.startTime = startTime
        self.endTime = endTime
        self.backgroundPattern = backgroundPattern
        self.filter = filter
    }

    public func isVisible(at time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }

    // MARK: - 解码兼容（filter 为新字段）

    enum CodingKeys: String, CodingKey {
        case id, kind, name, transform, zIndex, startTime, endTime, backgroundPattern, filter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ElementKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        transform = try container.decode(ElementTransform.self, forKey: .transform)
        zIndex = try container.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        startTime = try container.decodeIfPresent(TimeInterval.self, forKey: .startTime) ?? 0
        endTime = try container.decodeIfPresent(TimeInterval.self, forKey: .endTime) ?? .greatestFiniteMagnitude
        backgroundPattern = try container.decodeIfPresent(BackgroundPatternStyle.self, forKey: .backgroundPattern)
        filter = try container.decodeIfPresent(ElementFilter.self, forKey: .filter)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(transform, forKey: .transform)
        try container.encode(zIndex, forKey: .zIndex)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(backgroundPattern, forKey: .backgroundPattern)
        try container.encode(filter, forKey: .filter)
    }
}

// MARK: - Background

/// 背景线条图案样式
public enum BackgroundPattern: String, Codable, CaseIterable, Identifiable {
    /// 线条（角度任意：0 = 横线，45 = 斜线，90 = 竖线）
    case horizontal
    /// 马赛克（实心/空心方块棋盘格）
    case mosaic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .horizontal: NSLocalizedString("横线", comment: "Background pattern")
        case .mosaic: NSLocalizedString("马赛克", comment: "Background pattern")
        }
    }
}

/// 背景线条图案参数（代码绘制，可调样式/粗细/颜色/间距/角度）
public struct BackgroundPatternStyle: Codable, Equatable {
    public var pattern: BackgroundPattern
    public var lineWidth: CGFloat
    public var colorHex: String
    public var spacing: CGFloat
    /// 线条角度（度，0 = 横线，90 = 竖线，45 = 斜线）
    public var angle: CGFloat

    public init(
        pattern: BackgroundPattern = .horizontal,
        lineWidth: CGFloat = 4,
        colorHex: String = "B8BDC9",
        spacing: CGFloat = 48,
        angle: CGFloat = 0
    ) {
        self.pattern = pattern
        self.lineWidth = lineWidth
        self.colorHex = colorHex
        self.spacing = spacing
        self.angle = angle
    }
}

public struct BackgroundPreset: Codable, Equatable {
    public enum Kind: String, Codable {
        case clear
        case solid
        case gradient
        case image
        case pattern
    }

    public var kind: Kind
    /// hex 颜色，如 "1A1F38"
    public var topColor: String
    public var bottomColor: String
    /// 图片背景文件名（存于 Documents/Library/Backgrounds/，含预置图片）
    public var imageFileName: String?
    /// 线条图案参数（kind == .pattern 时使用）
    public var patternStyle: BackgroundPatternStyle?
    /// 叠加在底层背景上的线条/网格图案图层（透明底线条）
    public var patternOverlay: BackgroundPatternStyle?

    public init(
        kind: Kind,
        topColor: String,
        bottomColor: String,
        imageFileName: String? = nil,
        patternStyle: BackgroundPatternStyle? = nil,
        patternOverlay: BackgroundPatternStyle? = nil
    ) {
        self.kind = kind
        self.topColor = topColor
        self.bottomColor = bottomColor
        self.imageFileName = imageFileName
        self.patternStyle = patternStyle
        self.patternOverlay = patternOverlay
    }

    public static let clear = BackgroundPreset(kind: .clear, topColor: "000000", bottomColor: "000000")
    public static let dark = BackgroundPreset(kind: .gradient, topColor: "12162B", bottomColor: "0B0E1A")
    public static let parchment = BackgroundPreset(kind: .gradient, topColor: "E8D9B5", bottomColor: "C9AE7C")
}

// MARK: - Composition

public struct Composition: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var canvas: CanvasSpec
    public var duration: TimeInterval
    public var fps: Double
    public var elements: [CompositionElement]
    public var audioClips: [AudioClip]
    public var background: BackgroundPreset
    public var templateID: String?
    /// 裁剪区域（画布坐标系，nil = 全画布）；元素可超出画布，最终输出只保留该区域
    public var cropRect: CGRect?
    /// 文字元素库（元素 kind == .text 引用）
    public var texts: [TextElement]

    public init(
        id: UUID = UUID(),
        name: String,
        canvas: CanvasSpec,
        duration: TimeInterval = 3,
        fps: Double = 30,
        elements: [CompositionElement] = [],
        audioClips: [AudioClip] = [],
        background: BackgroundPreset = BackgroundPreset(kind: .solid, topColor: "FFFFFF", bottomColor: "FFFFFF"),
        templateID: String? = nil,
        cropRect: CGRect? = nil,
        texts: [TextElement] = []
    ) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.duration = duration
        self.fps = fps
        self.elements = elements
        self.audioClips = audioClips
        self.background = background
        self.templateID = templateID
        self.cropRect = cropRect
        self.texts = texts
    }

    public var canvasRect: CGRect {
        CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
    }

    // MARK: - 解码兼容（texts/filter 为新字段，旧工程 JSON 无此 key）

    enum CodingKeys: String, CodingKey {
        case id, name, canvas, duration, fps, elements, audioClips, background, templateID, cropRect, texts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        canvas = try container.decode(CanvasSpec.self, forKey: .canvas)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        fps = try container.decodeIfPresent(Double.self, forKey: .fps) ?? 30
        elements = try container.decodeIfPresent([CompositionElement].self, forKey: .elements) ?? []
        audioClips = try container.decodeIfPresent([AudioClip].self, forKey: .audioClips) ?? []
        background = try container.decodeIfPresent(BackgroundPreset.self, forKey: .background)
            ?? BackgroundPreset(kind: .solid, topColor: "FFFFFF", bottomColor: "FFFFFF")
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
        cropRect = try container.decodeIfPresent(CGRect.self, forKey: .cropRect)
        texts = try container.decodeIfPresent([TextElement].self, forKey: .texts) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(duration, forKey: .duration)
        try container.encode(fps, forKey: .fps)
        try container.encode(elements, forKey: .elements)
        try container.encode(audioClips, forKey: .audioClips)
        try container.encode(background, forKey: .background)
        try container.encode(templateID, forKey: .templateID)
        try container.encode(cropRect, forKey: .cropRect)
        try container.encode(texts, forKey: .texts)
    }

    /// 实际输出区域（裁剪后）
    public var renderRect: CGRect {
        cropRect ?? canvasRect
    }

    /// 根据时长更新所有元素的 endTime 上限，保证不超出
    public mutating func clampElementRanges() {
        for index in elements.indices {
            elements[index].endTime = min(elements[index].endTime, duration)
        }
    }
}
