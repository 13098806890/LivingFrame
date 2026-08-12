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

    public init(
        id: UUID = UUID(),
        kind: ElementKind,
        name: String,
        transform: ElementTransform = ElementTransform(),
        zIndex: Int = 0,
        startTime: TimeInterval = 0,
        endTime: TimeInterval = .greatestFiniteMagnitude
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.transform = transform
        self.zIndex = zIndex
        self.startTime = startTime
        self.endTime = endTime
    }

    public func isVisible(at time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }
}

// MARK: - Background

/// 背景线条图案样式
public enum BackgroundPattern: String, Codable, CaseIterable, Identifiable {
    case horizontal
    case diagonal
    case grid
    case mosaic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .horizontal: NSLocalizedString("横线", comment: "Background pattern")
        case .diagonal: NSLocalizedString("斜线", comment: "Background pattern")
        case .grid: NSLocalizedString("网格", comment: "Background pattern")
        case .mosaic: NSLocalizedString("马赛克", comment: "Background pattern")
        }
    }
}

/// 背景线条图案参数（代码绘制，可调样式/粗细/颜色/间距）
public struct BackgroundPatternStyle: Codable, Equatable {
    public var pattern: BackgroundPattern
    public var lineWidth: CGFloat
    public var colorHex: String
    public var spacing: CGFloat

    public init(
        pattern: BackgroundPattern = .horizontal,
        lineWidth: CGFloat = 2,
        colorHex: String = "B8BDC9",
        spacing: CGFloat = 72
    ) {
        self.pattern = pattern
        self.lineWidth = lineWidth
        self.colorHex = colorHex
        self.spacing = spacing
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
    /// 线条图案背景参数（kind == .pattern 时使用）
    public var patternStyle: BackgroundPatternStyle?

    public init(
        kind: Kind,
        topColor: String,
        bottomColor: String,
        imageFileName: String? = nil,
        patternStyle: BackgroundPatternStyle? = nil
    ) {
        self.kind = kind
        self.topColor = topColor
        self.bottomColor = bottomColor
        self.imageFileName = imageFileName
        self.patternStyle = patternStyle
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

    public init(
        id: UUID = UUID(),
        name: String,
        canvas: CanvasSpec,
        duration: TimeInterval = 3,
        fps: Double = 30,
        elements: [CompositionElement] = [],
        audioClips: [AudioClip] = [],
        background: BackgroundPreset = .dark,
        templateID: String? = nil,
        cropRect: CGRect? = nil
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
    }

    public var canvasRect: CGRect {
        CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
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
