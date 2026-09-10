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
    /// 工程级画布边框。它没有独立素材内容，渲染时使用 Composition 的
    /// canvasEdgeStyle，但作为元素参与时间轴层级排序。
    case canvasEdge
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
    case tornSoft
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
        case .tornSoft: NSLocalizedString("柔和手撕", comment: "Background edge")
        case .tornFibrous: NSLocalizedString("纤维手撕", comment: "Background edge")
        case .tornLayered: NSLocalizedString("卷角相纸", comment: "Background edge")
        case .comic: NSLocalizedString("漫画", comment: "Background edge")
        case .zigzag: NSLocalizedString("锯齿", comment: "Background edge")
        }
    }
}

/// 工程级画布外缘的样式。实际绘制由 `ElementKind.canvasEdge` 图层决定其 zIndex，
/// 和单个背景素材的分割边缘完全独立。
public enum CanvasEdgeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case tornSoft
    case tornLayered

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: NSLocalizedString("无", comment: "Canvas edge")
        case .tornSoft: NSLocalizedString("柔和手撕", comment: "Canvas edge")
        case .tornLayered: NSLocalizedString("卷角相纸", comment: "Canvas edge")
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

/// 一条可独立编辑的背景分割线。
/// 线的方向每 180° 重复，但保留原始角度值用于连续的 UI 交互。
public struct BackgroundDivider: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var angle: CGFloat
    public var offset: CGFloat
    public var pivot: CGPoint

    public init(
        id: UUID = UUID(),
        angle: CGFloat = 90,
        offset: CGFloat = 0,
        pivot: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) {
        self.id = id
        self.angle = angle
        self.offset = BackgroundDividerGeometry.clampedOffset(offset)
        self.pivot = BackgroundDividerGeometry.clampedPivot(pivot)
    }
}

/// 背景图片元素的独有设置。
/// cropScale/cropOffset 只影响图片在区域内部的取景，不改变元素本身在画布上的位置。
public struct BackgroundElementSettings: Codable, Equatable, Sendable {
    /// 背景素材取景缩放范围；低于 1× 可以看到更多原图内容。
    /// 保留一个极小的正数，避免缩放到 0 后素材无法再通过手势抓取；
    /// 对用户而言等同于不限制缩小范围。
    public static let minimumCropScale: CGFloat = 0.01
    public static let maximumCropScale: CGFloat = 4

    public var region: BackgroundRegion
    public var edgeStyle: BackgroundEdgeStyle
    public var cropScale: CGFloat
    public var cropOffset: CGPoint
    public var splitCount: BackgroundSplitCount
    /// 第一条分割线角度（度）。兼容旧数据时，第二条线默认使用 angle + 90°。
    public var dividerAngle: CGFloat
    /// 4 区模式下第二条分割线的独立角度（度）。
    public var secondaryDividerAngle: CGFloat
    /// 第一条分割线沿法线方向的偏移，单位为该方向可移动范围的比例（-0.85...0.85）。
    public var primaryDividerOffset: CGFloat
    /// 4 区模式下第二条分割线沿自身法线方向的独立偏移。
    public var secondaryDividerOffset: CGFloat
    /// 第一条分割线上的旋转中心，使用归一化 Core Image 坐标（原点在左下角）。
    public var primaryDividerPivot: CGPoint
    /// 4 区模式下第二条分割线上的旋转中心，使用归一化 Core Image 坐标。
    public var secondaryDividerPivot: CGPoint
    /// 当前正在编辑/显示标签的分区索引；保留用于兼容旧工程。
    public var selectedPartition: Int
    /// 此素材实例实际覆盖的分区。一个实例可以跨越多个分区，共享同一套取景参数。
    /// 空数组表示当前实例暂未分配到任何区域；旧数据解码时会回退到 selectedPartition。
    public var assignedPartitions: [Int]
    /// 背景图片的额外旋转次数，每次为顺时针 90°。
    /// 图片导入时先按 EXIF 方向校正；这个值只记录用户后续的主动旋转。
    public var rotationQuarterTurns: Int
    /// 当前工程中的全部分割线。旧字段保留用于兼容历史工程和单张背景编辑器。
    public var dividerLines: [BackgroundDivider]
    /// 拼接编辑器中的分割线布局是否已固定。单张背景编辑器不使用此字段。
    public var isDividerLayoutLocked: Bool

    public init(
        region: BackgroundRegion = .full,
        edgeStyle: BackgroundEdgeStyle = .flat,
        cropScale: CGFloat = 1,
        cropOffset: CGPoint = .zero,
        splitCount: BackgroundSplitCount = .full,
        dividerAngle: CGFloat = 90,
        secondaryDividerAngle: CGFloat? = nil,
        primaryDividerOffset: CGFloat = 0,
        secondaryDividerOffset: CGFloat = 0,
        primaryDividerPivot: CGPoint = CGPoint(x: 0.5, y: 0.5),
        secondaryDividerPivot: CGPoint = CGPoint(x: 0.5, y: 0.5),
        selectedPartition: Int = 0,
        assignedPartitions: [Int]? = nil,
        rotationQuarterTurns: Int = 0,
        dividerLines: [BackgroundDivider]? = nil,
        isDividerLayoutLocked: Bool = false
    ) {
        self.region = region
        self.edgeStyle = edgeStyle
        self.cropScale = cropScale
        self.cropOffset = cropOffset
        self.splitCount = splitCount
        self.dividerAngle = dividerAngle
        self.secondaryDividerAngle = secondaryDividerAngle ?? dividerAngle + 90
        self.primaryDividerOffset = BackgroundDividerGeometry.clampedOffset(primaryDividerOffset)
        self.secondaryDividerOffset = BackgroundDividerGeometry.clampedOffset(secondaryDividerOffset)
        self.primaryDividerPivot = BackgroundDividerGeometry.clampedPivot(primaryDividerPivot)
        self.secondaryDividerPivot = BackgroundDividerGeometry.clampedPivot(secondaryDividerPivot)
        self.selectedPartition = selectedPartition
        // nil 表示调用方没有提供新字段（兼容旧模型），需要回退到 selectedPartition；
        // 显式传入空数组则表示用户主动取消了所有区域，必须保留为空。
        let initialPartitions = assignedPartitions ?? [selectedPartition]
        self.assignedPartitions = Array(Set(initialPartitions.filter { $0 >= 0 })).sorted()
        self.rotationQuarterTurns = rotationQuarterTurns
        self.dividerLines = dividerLines ?? Self.legacyDividerLines(
            splitCount: splitCount,
            dividerAngle: dividerAngle,
            secondaryDividerAngle: self.secondaryDividerAngle,
            primaryDividerOffset: self.primaryDividerOffset,
            secondaryDividerOffset: self.secondaryDividerOffset,
            primaryDividerPivot: self.primaryDividerPivot,
            secondaryDividerPivot: self.secondaryDividerPivot
        )
        self.isDividerLayoutLocked = isDividerLayoutLocked
    }

    private enum CodingKeys: String, CodingKey {
        case region
        case edgeStyle
        case cropScale
        case cropOffset
        case splitCount
        case dividerAngle
        case secondaryDividerAngle
        case primaryDividerOffset
        case secondaryDividerOffset
        case primaryDividerPivot
        case secondaryDividerPivot
        case selectedPartition
        case assignedPartitions
        case rotationQuarterTurns
        case dividerLines
        case isDividerLayoutLocked
    }

    /// 新增旋转中心字段时兼容旧工程；旧数据默认回到画布中心。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            region: try container.decode(BackgroundRegion.self, forKey: .region),
            edgeStyle: try container.decode(BackgroundEdgeStyle.self, forKey: .edgeStyle),
            cropScale: try container.decode(CGFloat.self, forKey: .cropScale),
            cropOffset: try container.decode(CGPoint.self, forKey: .cropOffset),
            splitCount: try container.decode(BackgroundSplitCount.self, forKey: .splitCount),
            dividerAngle: try container.decode(CGFloat.self, forKey: .dividerAngle),
            secondaryDividerAngle: try container.decodeIfPresent(CGFloat.self, forKey: .secondaryDividerAngle),
            primaryDividerOffset: try container.decode(CGFloat.self, forKey: .primaryDividerOffset),
            secondaryDividerOffset: try container.decode(CGFloat.self, forKey: .secondaryDividerOffset),
            primaryDividerPivot: try container.decodeIfPresent(CGPoint.self, forKey: .primaryDividerPivot)
                ?? CGPoint(x: 0.5, y: 0.5),
            secondaryDividerPivot: try container.decodeIfPresent(CGPoint.self, forKey: .secondaryDividerPivot)
                ?? CGPoint(x: 0.5, y: 0.5),
            selectedPartition: try container.decode(Int.self, forKey: .selectedPartition),
            assignedPartitions: try container.decodeIfPresent([Int].self, forKey: .assignedPartitions),
            rotationQuarterTurns: try container.decode(Int.self, forKey: .rotationQuarterTurns),
            dividerLines: try container.decodeIfPresent([BackgroundDivider].self, forKey: .dividerLines),
            isDividerLayoutLocked: try container.decodeIfPresent(Bool.self, forKey: .isDividerLayoutLocked) ?? false
        )
    }

    /// 让旧的 splitCount 字段继续反映当前线数量，便于旧渲染缓存和旧代码兼容。
    public mutating func synchronizeLegacySplitCount() {
        splitCount = switch dividerLines.count {
        case 0: .full
        case 1: .two
        default: .four
        }
    }

    /// 当前实例覆盖的分区。旧工程解码时已经将缺失字段回退到 selectedPartition。
    public var resolvedAssignedPartitions: [Int] {
        Array(Set(assignedPartitions.filter { $0 >= 0 })).sorted()
    }

    private static func legacyDividerLines(
        splitCount: BackgroundSplitCount,
        dividerAngle: CGFloat,
        secondaryDividerAngle: CGFloat,
        primaryDividerOffset: CGFloat,
        secondaryDividerOffset: CGFloat,
        primaryDividerPivot: CGPoint,
        secondaryDividerPivot: CGPoint
    ) -> [BackgroundDivider] {
        switch splitCount {
        case .full:
            []
        case .two:
            [BackgroundDivider(
                angle: dividerAngle,
                offset: primaryDividerOffset,
                pivot: primaryDividerPivot
            )]
        case .four:
            [
                BackgroundDivider(
                    angle: dividerAngle,
                    offset: primaryDividerOffset,
                    pivot: primaryDividerPivot
                ),
                BackgroundDivider(
                    angle: secondaryDividerAngle,
                    offset: secondaryDividerOffset,
                    pivot: secondaryDividerPivot
                )
            ]
        }
    }

}

/// 背景分割线在预览与导出间共用的几何换算。
/// offset 使用相对画布中心沿法线方向可移动范围的比例，因而不随画布比例变化而失真。
public enum BackgroundDividerGeometry {
    public static let maximumOffset: CGFloat = 0.85

    public static func clampedOffset(_ offset: CGFloat) -> CGFloat {
        guard offset.isFinite else { return 0 }
        return min(max(offset, -maximumOffset), maximumOffset)
    }

    public static func clampedPivot(_ pivot: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(pivot.x.isFinite ? pivot.x : 0.5, 0), 1),
            y: min(max(pivot.y.isFinite ? pivot.y : 0.5, 0), 1)
        )
    }

    public static func offset(
        for dividerIndex: Int,
        settings: BackgroundElementSettings
    ) -> CGFloat {
        switch dividerIndex {
        case 0:
            return settings.primaryDividerOffset
        case 1:
            return settings.secondaryDividerOffset
        default:
            return settings.dividerLines.indices.contains(dividerIndex)
                ? settings.dividerLines[dividerIndex].offset
                : 0
        }
    }

    public static func lineCenter(
        in rect: CGRect,
        normal: CGPoint,
        offset: CGFloat
    ) -> CGPoint {
        let distance = clampedOffset(offset) * extent(in: rect, normal: normal)
        return CGPoint(x: rect.midX + normal.x * distance, y: rect.midY + normal.y * distance)
    }

    /// 根据一个固定的画布点，计算分割线相对于画布中心的归一化偏移。
    public static func offset(
        keeping point: CGPoint,
        normal: CGPoint,
        in rect: CGRect
    ) -> CGFloat {
        let lineDistance = (point.x - rect.midX) * normal.x
            + (point.y - rect.midY) * normal.y
        let lineExtent = extent(in: rect, normal: normal)
        guard lineExtent > 0.0001 else { return 0 }
        return clampedOffset(lineDistance / lineExtent)
    }

    /// 直线仍与画布相交时，中心沿法线方向可移动的最大距离。
    public static func extent(in rect: CGRect, normal: CGPoint) -> CGFloat {
        abs(normal.x) * rect.width / 2 + abs(normal.y) * rect.height / 2
    }

    /// A torn divider needs a small reveal for paper fibers, but adjacent
    /// partitions both contribute that reveal. Keep the per-side inset narrow
    /// so the combined gap never becomes wider than the rendered paper edge.
    public static func edgeInset(for style: BackgroundEdgeStyle, in rect: CGRect) -> CGFloat {
        let shortSide = min(rect.width, rect.height)
        switch style {
        case .tornSoft:
            return min(max(shortSide * 0.0032, 2), 7)
        case .tornFibrous:
            return min(max(shortSide * 0.0040, 2.5), 8)
        case .tornLayered:
            return min(max(shortSide * 0.0048, 3), 9)
        case .flat, .comic, .zigzag:
            return 0
        }
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
    /// 素材源内容的入点/出点（秒）。对视频、动态贴纸和动态背景生效；
    /// 静态文字/效果没有独立源帧时仅保留默认值。
    public var sourceStartTime: TimeInterval
    public var sourceEndTime: TimeInterval
    /// 第一次播放相对源区间起点的偏移（秒）。例如源区间为 2–5、相位为 1 时，
    /// 第一次播放从 3 开始；第一次回绕后仍从 2 开始。nil 表示从 sourceStartTime 开始。
    /// 使用可选值保持旧工程 Codable 数据兼容。
    public var sourcePlaybackOffset: TimeInterval?
    /// 总播放次数（1 = 仅一次）。nil 只用于兼容旧工程隐式延长的循环。
    public var playbackCount: Int?
    /// 元素级背景图案（垫在元素内容下层，nil = 无）
    public var backgroundPattern: BackgroundPatternStyle?
    /// 滤镜（作用于元素内容，nil = 原图）
    public var filter: ElementFilter?
    /// 仅对 background 元素生效；其它元素为 nil。
    public var backgroundSettings: BackgroundElementSettings?
    /// 仅对拼接创建的 background 元素生效；同一拼接组中的元素共享此标识。
    /// nil 表示这是从素材页独立添加的普通背景。
    public var collageGroupID: UUID?

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
        sourcePlaybackOffset: TimeInterval? = nil,
        playbackCount: Int = 1,
        backgroundPattern: BackgroundPatternStyle? = nil,
        filter: ElementFilter? = nil,
        backgroundSettings: BackgroundElementSettings? = nil,
        collageGroupID: UUID? = nil
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
        self.sourcePlaybackOffset = sourcePlaybackOffset
        self.playbackCount = max(playbackCount, 1)
        self.backgroundPattern = backgroundPattern
        self.filter = filter
        self.backgroundSettings = backgroundSettings
        self.collageGroupID = collageGroupID
    }

    public func isVisible(at time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
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
    /// 画布外缘的外观参数；对应的 canvasEdge 元素负责时间轴层级。
    public var canvasEdgeStyle: CanvasEdgeStyle
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
        self.templateID = templateID
        self.cropRect = cropRect
        self.texts = texts
        self.excludedCompositionFrames = excludedCompositionFrames
    }

    public var canvasRect: CGRect {
        CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
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
