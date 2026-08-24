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
    case background(backgroundID: String)
    case decoration(decorationID: String)
    case effect(effectID: String)
    case text(textID: String)
}

/// 背景图片元素在画布中的预设占用区域。
public enum BackgroundRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case upperHalf
    case lowerHalf
    case diagonal
    case quarter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full: NSLocalizedString("全画布", comment: "Background region")
        case .upperHalf: NSLocalizedString("上半", comment: "Background region")
        case .lowerHalf: NSLocalizedString("下半", comment: "Background region")
        case .diagonal: NSLocalizedString("对角", comment: "Background region")
        case .quarter: NSLocalizedString("四分之一", comment: "Background region")
        }
    }

    public func rect(in canvas: CGRect) -> CGRect {
        switch self {
        case .full, .diagonal:
            return canvas
        case .upperHalf:
            return CGRect(x: canvas.minX, y: canvas.midY, width: canvas.width, height: canvas.height / 2)
        case .lowerHalf:
            return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: canvas.height / 2)
        case .quarter:
            return CGRect(x: canvas.midX, y: canvas.midY, width: canvas.width / 2, height: canvas.height / 2)
        }
    }
}

/// 背景图片与画布交界处的边缘效果。
public enum BackgroundEdgeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case flat
    /// 兼容旧工程中的 `torn`；作为较柔和的手撕纸边继续保留。
    case torn
    /// 纤维更明显、起伏更丰富的手撕纸边。
    case tornFibrous
    /// 带有轻微白色纸边和接触阴影的叠层手撕纸效果。
    case tornLayered
    case comic
    case zigzag

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flat: NSLocalizedString("平整", comment: "Background edge")
        case .torn: NSLocalizedString("柔和手撕", comment: "Background edge")
        case .tornFibrous: NSLocalizedString("纤维手撕", comment: "Background edge")
        case .tornLayered: NSLocalizedString("卷角相纸", comment: "Background edge")
        case .comic: NSLocalizedString("漫画", comment: "Background edge")
        case .zigzag: NSLocalizedString("锯齿", comment: "Background edge")
        }
    }
}

/// 工程级画布外缘。它在所有元素合成完成后绘制，和单个背景素材的分割边缘完全独立。
public enum CanvasEdgeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case tornSoft
    case tornFibrous
    case tornLayered

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: NSLocalizedString("无", comment: "Canvas edge")
        case .tornSoft: NSLocalizedString("柔和手撕", comment: "Canvas edge")
        case .tornFibrous: NSLocalizedString("纤维手撕", comment: "Canvas edge")
        case .tornLayered: NSLocalizedString("卷角相纸", comment: "Canvas edge")
        }
    }
}

/// 画布相纸留白的宽度档位；以画布短边比例计算，横竖画幅观感一致。
public enum CanvasEdgeWidth: String, Codable, CaseIterable, Identifiable, Sendable {
    case narrow
    case standard
    case wide

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .narrow: NSLocalizedString("窄", comment: "Canvas edge width")
        case .standard: NSLocalizedString("标准", comment: "Canvas edge width")
        case .wide: NSLocalizedString("宽", comment: "Canvas edge width")
        }
    }
}

/// 背景图片的分区数量。新建分割线默认穿过画布中心，之后可平行移动。
public enum BackgroundSplitCount: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case two
    case four

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full: NSLocalizedString("整幅", comment: "Background split count")
        case .two: NSLocalizedString("2区", comment: "Background split count")
        case .four: NSLocalizedString("4区", comment: "Background split count")
        }
    }
}

/// 背景图片元素的独有设置。
/// cropScale/cropOffset 只影响图片在区域内部的取景，不改变元素本身在画布上的位置。
public struct BackgroundElementSettings: Codable, Equatable, Sendable {
    public var region: BackgroundRegion
    public var edgeStyle: BackgroundEdgeStyle
    public var cropScale: CGFloat
    public var cropOffset: CGPoint
    /// 新版分割模式；full 时保留并使用旧 region 字段，兼容已有工程。
    public var splitCount: BackgroundSplitCount
    /// 第一条分割线角度（度）。4区模式的第二条线自动为 angle + 90°。
    public var dividerAngle: CGFloat
    /// 第一条分割线沿法线方向的偏移，单位为该方向可移动范围的比例（-0.85...0.85）。
    public var primaryDividerOffset: CGFloat
    /// 4 区模式下第二条分割线沿自身法线方向的独立偏移。
    public var secondaryDividerOffset: CGFloat
    /// 当前被填充的分区索引：2区为 0...1，4区为 0...3。
    public var selectedPartition: Int
    /// 背景图片的额外旋转次数，每次为顺时针 90°。
    /// 图片导入时先按 EXIF 方向校正；这个值只记录用户后续的主动旋转。
    public var rotationQuarterTurns: Int

    public init(
        region: BackgroundRegion = .full,
        edgeStyle: BackgroundEdgeStyle = .flat,
        cropScale: CGFloat = 1,
        cropOffset: CGPoint = .zero,
        splitCount: BackgroundSplitCount = .full,
        dividerAngle: CGFloat = 90,
        primaryDividerOffset: CGFloat = 0,
        secondaryDividerOffset: CGFloat = 0,
        selectedPartition: Int = 0,
        rotationQuarterTurns: Int = 0
    ) {
        self.region = region
        self.edgeStyle = edgeStyle
        self.cropScale = cropScale
        self.cropOffset = cropOffset
        self.splitCount = splitCount
        self.dividerAngle = dividerAngle
        self.primaryDividerOffset = BackgroundDividerGeometry.clampedOffset(primaryDividerOffset)
        self.secondaryDividerOffset = BackgroundDividerGeometry.clampedOffset(secondaryDividerOffset)
        self.selectedPartition = selectedPartition
        self.rotationQuarterTurns = rotationQuarterTurns
    }

    private enum CodingKeys: String, CodingKey {
        case region, edgeStyle, cropScale, cropOffset, splitCount, dividerAngle, primaryDividerOffset, secondaryDividerOffset, selectedPartition, rotationQuarterTurns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        region = try container.decodeIfPresent(BackgroundRegion.self, forKey: .region) ?? .full
        edgeStyle = try container.decodeIfPresent(BackgroundEdgeStyle.self, forKey: .edgeStyle) ?? .flat
        cropScale = try container.decodeIfPresent(CGFloat.self, forKey: .cropScale) ?? 1
        cropOffset = try container.decodeIfPresent(CGPoint.self, forKey: .cropOffset) ?? .zero
        splitCount = try container.decodeIfPresent(BackgroundSplitCount.self, forKey: .splitCount) ?? .full
        dividerAngle = try container.decodeIfPresent(CGFloat.self, forKey: .dividerAngle) ?? 90
        primaryDividerOffset = BackgroundDividerGeometry.clampedOffset(
            try container.decodeIfPresent(CGFloat.self, forKey: .primaryDividerOffset) ?? 0
        )
        secondaryDividerOffset = BackgroundDividerGeometry.clampedOffset(
            try container.decodeIfPresent(CGFloat.self, forKey: .secondaryDividerOffset) ?? 0
        )
        selectedPartition = try container.decodeIfPresent(Int.self, forKey: .selectedPartition) ?? 0
        rotationQuarterTurns = try container.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(region, forKey: .region)
        try container.encode(edgeStyle, forKey: .edgeStyle)
        try container.encode(cropScale, forKey: .cropScale)
        try container.encode(cropOffset, forKey: .cropOffset)
        try container.encode(splitCount, forKey: .splitCount)
        try container.encode(dividerAngle, forKey: .dividerAngle)
        try container.encode(primaryDividerOffset, forKey: .primaryDividerOffset)
        try container.encode(secondaryDividerOffset, forKey: .secondaryDividerOffset)
        try container.encode(selectedPartition, forKey: .selectedPartition)
        try container.encode(rotationQuarterTurns, forKey: .rotationQuarterTurns)
    }
}

/// 背景分割线在预览与导出间共用的偏移换算。
/// offset 使用相对法线可移动范围的比例，因而不随画布比例变化而失真。
public enum BackgroundDividerGeometry {
    public static let maximumOffset: CGFloat = 0.85

    public static func clampedOffset(_ offset: CGFloat) -> CGFloat {
        guard offset.isFinite else { return 0 }
        return min(max(offset, -maximumOffset), maximumOffset)
    }

    public static func offset(
        for dividerIndex: Int,
        settings: BackgroundElementSettings
    ) -> CGFloat {
        dividerIndex == 0 ? settings.primaryDividerOffset : settings.secondaryDividerOffset
    }

    /// 法线在当前坐标系下为单位向量（Core Image 与 SwiftUI 的 y 轴方向不同，调用方传入对应法线）。
    public static func center(
        in rect: CGRect,
        normal: CGPoint,
        offset: CGFloat
    ) -> CGPoint {
        let distance = clampedOffset(offset) * extent(in: rect, normal: normal)
        return CGPoint(x: rect.midX + normal.x * distance, y: rect.midY + normal.y * distance)
    }

    /// 直线仍与画布相交时，中心沿法线方向可移动的最大距离。
    public static func extent(in rect: CGRect, normal: CGPoint) -> CGFloat {
        abs(normal.x) * rect.width / 2 + abs(normal.y) * rect.height / 2
    }
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
    /// 素材源内容的入点/出点（秒）。只对 clip 元素生效；默认覆盖完整素材。
    public var sourceStartTime: TimeInterval
    public var sourceEndTime: TimeInterval
    /// 元素级背景图案（垫在元素内容下层，nil = 无）
    public var backgroundPattern: BackgroundPatternStyle?
    /// 滤镜（作用于元素内容，nil = 原图）
    public var filter: ElementFilter?
    /// 仅对 background 元素生效；旧版本工程解码时为 nil。
    public var backgroundSettings: BackgroundElementSettings?

    public init(
        id: UUID = UUID(),
        kind: ElementKind,
        name: String,
        transform: ElementTransform = ElementTransform(),
        zIndex: Int = 0,
        startTime: TimeInterval = 0,
        endTime: TimeInterval = .greatestFiniteMagnitude,
        sourceStartTime: TimeInterval = 0,
        sourceEndTime: TimeInterval = .greatestFiniteMagnitude,
        backgroundPattern: BackgroundPatternStyle? = nil,
        filter: ElementFilter? = nil,
        backgroundSettings: BackgroundElementSettings? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.transform = transform
        self.zIndex = zIndex
        self.startTime = startTime
        self.endTime = endTime
        self.sourceStartTime = sourceStartTime
        self.sourceEndTime = sourceEndTime
        self.backgroundPattern = backgroundPattern
        self.filter = filter
        self.backgroundSettings = backgroundSettings
    }

    public func isVisible(at time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }

    // MARK: - 解码兼容（filter/backgroundSettings 为新字段）

    enum CodingKeys: String, CodingKey {
        case id, kind, name, transform, zIndex, startTime, endTime, sourceStartTime, sourceEndTime, backgroundPattern, filter,
             backgroundSettings
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
        sourceStartTime = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceStartTime) ?? 0
        sourceEndTime = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceEndTime) ?? .greatestFiniteMagnitude
        backgroundPattern = try container.decodeIfPresent(BackgroundPatternStyle.self, forKey: .backgroundPattern)
        filter = try container.decodeIfPresent(ElementFilter.self, forKey: .filter)
        backgroundSettings = try container.decodeIfPresent(BackgroundElementSettings.self, forKey: .backgroundSettings)
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
        try container.encode(sourceStartTime, forKey: .sourceStartTime)
        try container.encode(sourceEndTime, forKey: .sourceEndTime)
        try container.encode(backgroundPattern, forKey: .backgroundPattern)
        try container.encode(filter, forKey: .filter)
        try container.encode(backgroundSettings, forKey: .backgroundSettings)
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
    /// 画布的最终外缘叠层，不隶属于任何动态背景/元素。
    public var canvasEdgeStyle: CanvasEdgeStyle
    public var canvasEdgeWidth: CanvasEdgeWidth
    public var templateID: String?
    /// 裁剪区域（画布坐标系，nil = 全画布）；元素可超出画布，最终输出只保留该区域
    public var cropRect: CGRect?
    /// 文字元素库（元素 kind == .text 引用）
    public var texts: [TextElement]
    /// 合成画面的排除帧。仅在编辑器选中背景后编辑帧时使用，播放时由前一合成帧补位。
    public var excludedCompositionFrames: Set<Int>

    public init(
        id: UUID = UUID(),
        name: String,
        canvas: CanvasSpec,
        duration: TimeInterval = 3,
        fps: Double = 30,
        elements: [CompositionElement] = [],
        audioClips: [AudioClip] = [],
        background: BackgroundPreset = BackgroundPreset(kind: .solid, topColor: "FFFFFF", bottomColor: "FFFFFF"),
        canvasEdgeStyle: CanvasEdgeStyle = .none,
        canvasEdgeWidth: CanvasEdgeWidth = .standard,
        templateID: String? = nil,
        cropRect: CGRect? = nil,
        texts: [TextElement] = [],
        excludedCompositionFrames: Set<Int> = []
    ) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.duration = duration
        self.fps = fps
        self.elements = elements
        self.audioClips = audioClips
        self.background = background
        self.canvasEdgeStyle = canvasEdgeStyle
        self.canvasEdgeWidth = canvasEdgeWidth
        self.templateID = templateID
        self.cropRect = cropRect
        self.texts = texts
        self.excludedCompositionFrames = excludedCompositionFrames
    }

    public var canvasRect: CGRect {
        CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
    }

    // MARK: - 解码兼容（texts/filter 为新字段，旧工程 JSON 无此 key）

    enum CodingKeys: String, CodingKey {
        case id, name, canvas, duration, fps, elements, audioClips, background, canvasEdgeStyle, canvasEdgeWidth, templateID, cropRect, texts,
             excludedCompositionFrames
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
        canvasEdgeStyle = try container.decodeIfPresent(CanvasEdgeStyle.self, forKey: .canvasEdgeStyle) ?? .none
        canvasEdgeWidth = try container.decodeIfPresent(CanvasEdgeWidth.self, forKey: .canvasEdgeWidth) ?? .standard
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
        cropRect = try container.decodeIfPresent(CGRect.self, forKey: .cropRect)
        texts = try container.decodeIfPresent([TextElement].self, forKey: .texts) ?? []
        excludedCompositionFrames = try container.decodeIfPresent(
            Set<Int>.self,
            forKey: .excludedCompositionFrames
        ) ?? []
    }

    /// 工程在当前 FPS 下的帧数。
    public var frameCount: Int {
        guard duration.isFinite, fps.isFinite, fps > 0 else { return 0 }
        return max(Int((duration * fps).rounded(.up)), 1)
    }

    /// 将时间轴帧映射到实际应显示的合成帧。排除位置由前面最近的保留帧填补；
    /// 开头没有前帧时使用后面第一张保留帧，全部排除则回退原帧。
    public func compositionPlaybackFrameIndex(
        for frameIndex: Int,
        reversed: Bool = false
    ) -> Int {
        let count = frameCount
        guard count > 0 else { return 0 }
        let clamped = min(max(frameIndex, 0), count - 1)
        guard excludedCompositionFrames.contains(clamped) else { return clamped }

        if reversed {
            if clamped + 1 < count,
               let next = (clamped + 1..<count).first(where: {
                   !excludedCompositionFrames.contains($0)
               }) {
                return next
            }
            var fallback = clamped - 1
            while fallback >= 0 {
                if !excludedCompositionFrames.contains(fallback) { return fallback }
                fallback -= 1
            }
        } else {
            var previous = clamped - 1
            while previous >= 0 {
                if !excludedCompositionFrames.contains(previous) { return previous }
                previous -= 1
            }
            if clamped + 1 < count,
               let next = (clamped + 1..<count).first(where: {
                   !excludedCompositionFrames.contains($0)
               }) {
                return next
            }
        }
        return clamped
    }

    /// 合成渲染使用的实际时间。没有工程级帧编辑时保留连续时间，避免改变原有播放精度。
    public func compositionPlaybackTime(
        for time: TimeInterval,
        reversed: Bool = false
    ) -> TimeInterval {
        guard !excludedCompositionFrames.isEmpty, time.isFinite, fps.isFinite, fps > 0 else {
            return time
        }
        let index = Int((max(time, 0) * fps).rounded(.down))
        return TimeInterval(compositionPlaybackFrameIndex(for: index, reversed: reversed)) / fps
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
        try container.encode(excludedCompositionFrames, forKey: .excludedCompositionFrames)
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
