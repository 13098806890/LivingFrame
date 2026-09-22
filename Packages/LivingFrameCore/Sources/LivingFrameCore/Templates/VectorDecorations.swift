import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

private final class StickerSelectionBoundsBox: NSObject {
    let rect: CGRect

    init(_ rect: CGRect) {
        self.rect = rect
    }
}

private final class StickerFrameBox: NSObject {
    let frames: [CGImage]

    init(_ frames: [CGImage]) {
        self.frames = frames
    }
}

public enum StickerCategory: String, CaseIterable, Equatable, Sendable {
    case doodle
    case emoji
    case fruit
    case aiSticker
    case logo

    /// AI face stickers remain readable for existing saved compositions, but
    /// are not exposed to new users while the feature is hidden.
    public static let allCases: [StickerCategory] = [
        .doodle, .emoji, .fruit, .logo
    ]

    public var title: String {
        switch self {
        case .doodle: NSLocalizedString("涂鸦", comment: "Sticker category")
        case .emoji: NSLocalizedString("emoji", comment: "Sticker category")
        case .fruit: NSLocalizedString("水果", comment: "Sticker category")
        case .aiSticker: NSLocalizedString("AI贴纸", comment: "Sticker category")
        case .logo: NSLocalizedString("logo", comment: "Sticker category")
        }
    }

    public var requiresPro: Bool {
        self == .aiSticker
    }

    public var isFaceSticker: Bool {
        requiresPro
    }
}

public enum StickerRenderingMode: String, Equatable, Sendable {
    /// Select one authored 2D view and place it with the tracked landmarks.
    case multiView2D
    /// Cross-fade authored image views between tracked yaw angles.
    case rendered3DViews
    /// Render a procedural 3D model at the tracked yaw on demand.
    case rendered3DModel
    case standard

    /// Short label shown in the sticker picker and its comparison preview.
    public var previewTitle: String {
        switch self {
        case .multiView2D:
            return "方案 1 · 多视角 2D"
        case .rendered3DViews:
            return "方案 2 · 预渲染视角"
        case .rendered3DModel:
            return "方案 3 · 真 3D 模型"
        case .standard:
            return "普通贴纸"
        }
    }
}

public struct StickerDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: StickerCategory
    public let resourceName: String
    public let resourceExtension: String
    public let isFrameSequence: Bool
    public let frameCount: Int
    public let frameDuration: TimeInterval
    public let faceAnchors: StickerFaceAnchors?
    public let faceViews: [StickerFaceView]?
    /// Sign correction for authored view sets whose source images use the
    /// opposite horizontal convention from Vision's yaw value.
    public let faceViewYawSign: CGFloat
    /// Sign correction for authored vertical views. This is kept per asset set
    /// because image-generation prompts and Vision use different pitch wording.
    public let faceViewPitchSign: CGFloat
    public let renderingMode: StickerRenderingMode
    /// When present, the sticker is rasterized from the platform's native
    /// emoji font instead of being loaded from a bundled image resource.
    public let nativeEmoji: String?

    public var localizedName: String {
        let key: String
        switch id {
        case "sticker-logo-hand-lettered": key = "手写字标"
        case "sticker-logo-doodle": key = "涂鸦字标"
        case "sticker-logo-crayon": key = "蜡笔字标"
        case "sticker-ai-sunglasses-crayon-3d": key = "蜡笔墨镜 · 3D"
        case "sticker-ai-cap-crayon-3d": key = "蜡笔帽子 · 3D"
        default: key = name
        }
        return NSLocalizedString(key, comment: "Sticker name")
    }

    public var localizedDescription: String {
        let key: String
        switch category {
        case .doodle:
            key = "为画面增添趣味的动态涂鸦装饰。"
        case .emoji:
            key = "使用系统的 Apple Color Emoji 风格表情。"
        case .fruit:
            key = "让水果图案以轻快动画点亮画面。"
        case .aiSticker:
            switch id {
            case "sticker-ai-cap-crayon-3d":
                key = "使用 3D 帽子视角渲染，并随人物头部转动。"
            default:
                switch renderingMode {
                case .multiView2D:
                    key = "根据人脸角度切换 2D 墨镜视图，并自动贴合双眼。"
                case .rendered3DViews:
                    key = "使用多张预渲染视角图，随人脸角度平滑变化。"
                case .rendered3DModel:
                    key = "直接渲染 3D 模型，随人脸角度实时变化。"
                case .standard:
                    key = "自动贴合人脸位置。"
                }
            }
        case .logo:
            key = "GIFBloom 品牌字标动态贴纸。"
        }
        return NSLocalizedString(key, comment: "Sticker description")
    }

    public var defaultDuration: TimeInterval {
        Double(frameCount) * frameDuration
    }

    public init(
        id: String,
        name: String,
        category: StickerCategory,
        resourceName: String,
        resourceExtension: String,
        isFrameSequence: Bool,
        frameCount: Int,
        frameDuration: TimeInterval = 0.1,
        faceAnchors: StickerFaceAnchors? = nil,
        faceViews: [StickerFaceView]? = nil,
        faceViewYawSign: CGFloat = 1,
        faceViewPitchSign: CGFloat = 1,
        renderingMode: StickerRenderingMode = .standard,
        nativeEmoji: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.resourceName = resourceName
        self.resourceExtension = resourceExtension
        self.isFrameSequence = isFrameSequence
        self.frameCount = frameCount
        self.frameDuration = max(frameDuration, 0.01)
        self.faceAnchors = faceAnchors
        self.faceViews = faceViews?.sorted {
            if abs($0.yawAngle - $1.yawAngle) > 0.0001 {
                return $0.yawAngle < $1.yawAngle
            }
            return $0.pitchAngle < $1.pitchAngle
        }
        self.faceViewYawSign = faceViewYawSign < 0 ? -1 : 1
        self.faceViewPitchSign = faceViewPitchSign < 0 ? -1 : 1
        self.renderingMode = renderingMode
        self.nativeEmoji = nativeEmoji
    }
}

/// A 2D render authored for one head yaw. These views can be selected directly
/// or interpolated when they were rendered from one consistent 3D model.
public struct StickerFaceView: Equatable, Sendable {
    public let yawAngle: CGFloat
    public let pitchAngle: CGFloat
    public let resourceName: String
    public let anchors: StickerFaceAnchors

    public init(
        yawAngle: CGFloat,
        pitchAngle: CGFloat = 0,
        resourceName: String,
        anchors: StickerFaceAnchors
    ) {
        self.yawAngle = max(yawAngle, 0)
        self.pitchAngle = pitchAngle
        self.resourceName = resourceName
        self.anchors = anchors
    }
}

public struct StickerFaceViewSelection: Equatable, Sendable {
    public let first: StickerFaceView
    public let second: StickerFaceView
    public let blend: CGFloat
    public let isMirrored: Bool

    public var nearestView: StickerFaceView {
        blend < 0.5 ? first : second
    }

    public var anchors: StickerFaceAnchors {
        let firstAnchors = isMirrored ? Self.mirrored(first.anchors) : first.anchors
        let secondAnchors = isMirrored ? Self.mirrored(second.anchors) : second.anchors
        return StickerFaceAnchors(
            leftEye: Self.interpolate(firstAnchors.leftEye, secondAnchors.leftEye, amount: blend),
            rightEye: Self.interpolate(firstAnchors.rightEye, secondAnchors.rightEye, amount: blend),
            ear: Self.interpolate(firstAnchors.ear, secondAnchors.ear, amount: blend)
        )
    }

    public func anchors(for renderingMode: StickerRenderingMode) -> StickerFaceAnchors {
        guard renderingMode == .multiView2D else { return anchors }
        let selected = isMirrored ? Self.mirrored(nearestView.anchors) : nearestView.anchors
        return selected
    }

    private static func mirrored(_ anchors: StickerFaceAnchors) -> StickerFaceAnchors {
        StickerFaceAnchors(
            leftEye: CGPoint(x: 1 - anchors.rightEye.x, y: anchors.rightEye.y),
            rightEye: CGPoint(x: 1 - anchors.leftEye.x, y: anchors.leftEye.y),
            ear: anchors.ear.map { CGPoint(x: 1 - $0.x, y: $0.y) }
        )
    }

    private static func interpolate(_ first: CGPoint, _ second: CGPoint, amount: CGFloat) -> CGPoint {
        CGPoint(
            x: first.x + (second.x - first.x) * amount,
            y: first.y + (second.y - first.y) * amount
        )
    }

    private static func interpolate(_ first: CGPoint?, _ second: CGPoint?, amount: CGFloat) -> CGPoint? {
        switch (first, second) {
        case let (.some(a), .some(b)): interpolate(a, b, amount: amount)
        case let (.some(value), .none), let (.none, .some(value)): value
        case (.none, .none): nil
        }
    }
}

/// 导出时叠加的品牌水印。每次导出固定使用一个贴纸，避免动画逐帧切换 logo。
public struct ExportWatermark: Equatable, Sendable {
    public let decorationID: String
    public let opacity: CGFloat

    public init(decorationID: String, opacity: CGFloat = 0.6) {
        self.decorationID = decorationID
        self.opacity = min(max(opacity, 0), 1)
    }
}

/// 装饰绘制：CoreGraphics 代码生成 + 动图贴纸（PNG 帧序列，Bundle 内资源）
/// 体积 0 的矢量装饰 vs 位图贴纸双平台复用
public struct DecorationRenderer {
    private let cache = NSCache<NSString, CIImage>()
    private static let lock = NSLock()
    private static let previewCIContext = CIContext()
    /// 动图贴纸帧缓存。NSCache 会在内存紧张时自动回收，避免未来增加贴纸后永久持有所有帧。
    private static let stickerFrameCache: NSCache<NSString, StickerFrameBox> = {
        let cache = NSCache<NSString, StickerFrameBox>()
        cache.countLimit = 8
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private static let faceViewImageCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private static let stickerSelectionBoundsCache: NSCache<NSString, StickerSelectionBoundsBox> = {
        let cache = NSCache<NSString, StickerSelectionBoundsBox>()
        cache.countLimit = 64
        return cache
    }()

    static func clearSharedCaches() {
        lock.lock()
        stickerFrameCache.removeAllObjects()
        faceViewImageCache.removeAllObjects()
        stickerSelectionBoundsCache.removeAllObjects()
        lock.unlock()
    }

    /// Additional emoji face stickers. Keeping the emoji as Unicode
    /// data lets the system render the current Apple artwork at runtime.
    private static let additionalEmojiStickers: [StickerDefinition] = [
        ("grinning", "咧嘴", "😀"),
        ("grin", "开心", "😄"),
        ("smile-big", "大笑", "😃"),
        ("laughing", "嘻笑", "😆"),
        ("sweat-smile", "苦笑", "😅"),
        ("rofl", "笑翻", "🤣"),
        ("slight-smile", "微微笑", "🙂"),
        ("upside-down", "反向笑", "🙃"),
        ("smiling-hearts", "宠溺", "🥰"),
        ("kiss", "飞吻", "😘"),
        ("kissing", "亲亲", "😗"),
        ("kissing-smiling", "亲亲笑", "😙"),
        ("kissing-closed-eyes", "闭眼亲亲", "😚"),
        ("yum", "好吃", "😋"),
        ("tongue", "吐舌", "😛"),
        ("wink-tongue", "调皮", "😜"),
        ("crazy", "疯狂", "🤪"),
        ("raised-eyebrow", "挑眉", "🤨"),
        ("monocle", "单片眼镜", "🧐"),
        ("nerd", "书呆子", "🤓"),
        ("cool", "墨镜", "😎"),
        ("star-struck", "星星眼", "🤩"),
        ("partying", "庆祝", "🥳"),
        ("smirk", "得意", "😏"),
        ("unamused", "不屑", "😒"),
        ("disappointed", "失望", "😞"),
        ("pensive", "忧郁", "😔"),
        ("worried", "担心", "😟"),
        ("confused", "困惑", "😕"),
        ("frown", "不开心", "🙁"),
        ("sad", "难过", "☹️"),
        ("persevering", "痛苦", "😣"),
        ("confounded", "纠结", "😖"),
        ("tired", "疲惫", "😫"),
        ("weary", "累坏", "😩"),
        ("pleading", "撒娇", "🥺"),
        ("sob", "流泪", "😢"),
        ("triumph", "鼻孔喷气", "😤"),
        ("cursing", "爆粗", "🤬"),
        ("scream", "惊恐", "😱"),
        ("fearful", "害怕", "😨"),
        ("anxious", "冷汗", "😰"),
        ("sad-sweat", "失落", "😥"),
        ("sweat", "汗颜", "😓"),
        ("cold", "冻脸", "🥶"),
        ("hot", "热脸", "🥵"),
        ("hugging", "拥抱", "🤗"),
        ("lying", "撒谎", "🤥"),
        ("hand-over-mouth", "偷笑", "🤭"),
        ("shushing", "嘘", "🤫"),
        ("salute", "敬礼", "🫡"),
        ("grimacing", "尴尬", "😬"),
        ("neutral", "面无表情", "😐"),
        ("expressionless", "无语", "😑"),
        ("no-mouth", "沉默", "😶"),
        ("dotted-face", "隐身", "🫥"),
        ("melting", "融化", "🫠")
    ].map { item in
        StickerDefinition(
            id: "sticker-apple-emoji-\(item.0)", name: item.1, category: .emoji,
            resourceName: "apple-emoji-\(item.0)", resourceExtension: "native",
            isFrameSequence: false, frameCount: 1, frameDuration: 1.2,
            nativeEmoji: item.2
        )
    }

    public static let stickerCatalog: [StickerDefinition] = [
        StickerDefinition(
            id: "sticker-firework", name: "烟花", category: .doodle,
            resourceName: "firework-frame-%02d", resourceExtension: "png",
            isFrameSequence: true, frameCount: 9
        ),
        StickerDefinition(
            id: "sticker-doodle-orange-bubble", name: "橙色气泡框", category: .doodle,
            resourceName: "doodle-orange-bubble", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-color-exclamation", name: "彩色感叹号", category: .doodle,
            resourceName: "doodle-color-exclamation", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-tangle", name: "乱麻", category: .doodle,
            resourceName: "doodle-tangle", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5
        ),
        StickerDefinition(
            id: "sticker-doodle-tomato", name: "番茄", category: .doodle,
            resourceName: "doodle-tomato", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-triangle-flag", name: "三角彩旗", category: .doodle,
            resourceName: "doodle-triangle-flag", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-lightbulb", name: "灯泡", category: .doodle,
            resourceName: "doodle-lightbulb", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-frame", name: "边框", category: .doodle,
            resourceName: "doodle-frame", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-red-flower", name: "红色花朵", category: .doodle,
            resourceName: "doodle-red-flower", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-insult", name: "骂人", category: .doodle,
            resourceName: "doodle-insult", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-summer", name: "夏日", category: .doodle,
            resourceName: "doodle-summer", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-sweat", name: "流汗", category: .doodle,
            resourceName: "doodle-sweat", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5
        ),
        StickerDefinition(
            id: "sticker-doodle-rainbow", name: "彩虹", category: .doodle,
            resourceName: "doodle-rainbow", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-loading", name: "黄色loading", category: .doodle,
            resourceName: "doodle-loading", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 7
        ),
        StickerDefinition(
            id: "sticker-doodle-red-bow", name: "红色蝴蝶结", category: .doodle,
            resourceName: "doodle-red-bow", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-number-1", name: "数字1", category: .doodle,
            resourceName: "doodle-number-1", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 7
        ),
        StickerDefinition(
            id: "sticker-doodle-number-3", name: "数字3", category: .doodle,
            resourceName: "doodle-number-3", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 7
        ),
        StickerDefinition(
            id: "sticker-doodle-number-2", name: "数字2", category: .doodle,
            resourceName: "doodle-number-2", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 7
        ),
        StickerDefinition(
            id: "sticker-doodle-pink-flower", name: "粉色小花", category: .doodle,
            resourceName: "doodle-pink-flower", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-sun", name: "太阳", category: .doodle,
            resourceName: "doodle-sun", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-kite", name: "风筝", category: .doodle,
            resourceName: "doodle-kite", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 3
        ),
        StickerDefinition(
            id: "sticker-doodle-cake", name: "蛋糕", category: .doodle,
            resourceName: "doodle-cake", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 8
        ),
        StickerDefinition(
            id: "sticker-doodle-calendar-clock", name: "日历时钟", category: .doodle,
            resourceName: "doodle-calendar-clock", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 108
        ),
        StickerDefinition(
            id: "sticker-doodle-simple-clock", name: "简单时钟", category: .doodle,
            resourceName: "doodle-simple-clock", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 108
        ),
        StickerDefinition(
            id: "sticker-apple-emoji-smile", name: "微笑", category: .emoji,
            resourceName: "apple-emoji-smile", resourceExtension: "native",
            isFrameSequence: false, frameCount: 1, frameDuration: 1.2,
            nativeEmoji: "😊"
        ),
        StickerDefinition(
            id: "sticker-apple-emoji-laugh", name: "笑哭", category: .emoji,
            resourceName: "apple-emoji-laugh", resourceExtension: "native",
            isFrameSequence: false, frameCount: 1, frameDuration: 1.2,
            nativeEmoji: "😂"
        ),
        StickerDefinition(
            id: "sticker-apple-emoji-love", name: "爱心眼", category: .emoji,
            resourceName: "apple-emoji-love", resourceExtension: "native",
            isFrameSequence: false, frameCount: 1, frameDuration: 1.2,
            nativeEmoji: "😍"
        ),
        StickerDefinition(
            id: "sticker-apple-emoji-wink", name: "眨眼", category: .emoji,
            resourceName: "apple-emoji-wink", resourceExtension: "native",
            isFrameSequence: false, frameCount: 1, frameDuration: 1.2,
            nativeEmoji: "😉"
        ),
        StickerDefinition(
            id: "sticker-apple-emoji-cry", name: "大哭", category: .emoji,
            resourceName: "apple-emoji-cry", resourceExtension: "native",
            isFrameSequence: false, frameCount: 1, frameDuration: 1.2,
            nativeEmoji: "😭"
        ),
        StickerDefinition(
            id: "sticker-apple-emoji-think", name: "思考", category: .emoji,
            resourceName: "apple-emoji-think", resourceExtension: "native",
            isFrameSequence: false, frameCount: 1, frameDuration: 1.2,
            nativeEmoji: "🤔"
        ),
        StickerDefinition(
            id: "sticker-apple-emoji-surprise", name: "惊讶", category: .emoji,
            resourceName: "apple-emoji-surprise", resourceExtension: "native",
            isFrameSequence: false, frameCount: 1, frameDuration: 1.2,
            nativeEmoji: "😮"
        ),
        StickerDefinition(
            id: "sticker-apple-emoji-angry", name: "生气", category: .emoji,
            resourceName: "apple-emoji-angry", resourceExtension: "native",
            isFrameSequence: false, frameCount: 1, frameDuration: 1.2,
            nativeEmoji: "😡"
        )
    ] + additionalEmojiStickers + [
        StickerDefinition(
            id: "sticker-fruit-apple", name: "苹果", category: .fruit,
            resourceName: "fruit-apple", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-banana", name: "香蕉", category: .fruit,
            resourceName: "fruit-banana", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-orange", name: "橙子", category: .fruit,
            resourceName: "fruit-orange", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-strawberry", name: "草莓", category: .fruit,
            resourceName: "fruit-strawberry", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-grapes", name: "葡萄", category: .fruit,
            resourceName: "fruit-grapes", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-watermelon", name: "西瓜", category: .fruit,
            resourceName: "fruit-watermelon", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-peaches", name: "桃子", category: .fruit,
            resourceName: "fruit-peaches", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-pineapple", name: "菠萝", category: .fruit,
            resourceName: "fruit-pineapple", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-lemon", name: "柠檬", category: .fruit,
            resourceName: "fruit-lemon", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-pear", name: "梨", category: .fruit,
            resourceName: "fruit-pear", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-mango", name: "芒果", category: .fruit,
            resourceName: "fruit-mango", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-kiwi", name: "猕猴桃", category: .fruit,
            resourceName: "fruit-kiwi", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-cherries", name: "樱桃", category: .fruit,
            resourceName: "fruit-cherries", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-avocado", name: "牛油果", category: .fruit,
            resourceName: "fruit-avocado", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-blueberries", name: "蓝莓", category: .fruit,
            resourceName: "fruit-blueberries", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-fruit-plum", name: "李子", category: .fruit,
            resourceName: "fruit-plum", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 5, frameDuration: 0.2
        ),
        StickerDefinition(
            id: "sticker-ai-sunglasses-3d", name: "紫晶墨镜 · 3D视角", category: .aiSticker,
            resourceName: "sunglasses-3d-front", resourceExtension: "png",
            isFrameSequence: false, frameCount: 1, frameDuration: 1,
            faceAnchors: StickerFaceAnchors(
                leftEye: CGPoint(x: 0.325, y: 0.500),
                rightEye: CGPoint(x: 0.675, y: 0.500)
            ),
            faceViews: [
                StickerFaceView(
                    yawAngle: 0,
                    resourceName: "sunglasses-3d-front",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.325, y: 0.500),
                        rightEye: CGPoint(x: 0.675, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0.70,
                    resourceName: "sunglasses-3d-three-quarter",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.393, y: 0.500),
                        rightEye: CGPoint(x: 0.661, y: 0.500),
                        ear: CGPoint(x: 0.040, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 1.30,
                    resourceName: "sunglasses-3d-profile",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.493, y: 0.500),
                        rightEye: CGPoint(x: 0.587, y: 0.500),
                        ear: CGPoint(x: 0.050, y: 0.500)
                    )
                )
            ],
            renderingMode: .rendered3DViews
        ),
        StickerDefinition(
            id: "sticker-ai-sunglasses-crayon-3d", name: "蜡笔墨镜 · 3D", category: .aiSticker,
            resourceName: "sunglasses-crayon-3d-front", resourceExtension: "png",
            isFrameSequence: false, frameCount: 1, frameDuration: 1,
            faceAnchors: StickerFaceAnchors(
                leftEye: CGPoint(x: 0.300, y: 0.500),
                rightEye: CGPoint(x: 0.700, y: 0.500)
            ),
            faceViews: [
                StickerFaceView(
                    yawAngle: 0,
                    resourceName: "sunglasses-crayon-3d-front",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.300, y: 0.500),
                        rightEye: CGPoint(x: 0.700, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0.70,
                    resourceName: "sunglasses-crayon-3d-three-quarter",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.390, y: 0.500),
                        rightEye: CGPoint(x: 0.680, y: 0.500),
                        ear: CGPoint(x: 0.840, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 1.30,
                    resourceName: "sunglasses-crayon-3d-profile",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.120, y: 0.500),
                        rightEye: CGPoint(x: 0.290, y: 0.500),
                        ear: CGPoint(x: 0.950, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0,
                    pitchAngle: 0.45,
                    resourceName: "sunglasses-crayon-3d-front-pitch-up",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.300, y: 0.500),
                        rightEye: CGPoint(x: 0.700, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0,
                    pitchAngle: -0.45,
                    resourceName: "sunglasses-crayon-3d-front-pitch-down",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.300, y: 0.500),
                        rightEye: CGPoint(x: 0.700, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0.70,
                    pitchAngle: 0.45,
                    resourceName: "sunglasses-crayon-3d-three-quarter-pitch-up",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.390, y: 0.500),
                        rightEye: CGPoint(x: 0.680, y: 0.500),
                        ear: CGPoint(x: 0.840, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0.70,
                    pitchAngle: -0.45,
                    resourceName: "sunglasses-crayon-3d-three-quarter-pitch-down",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.390, y: 0.500),
                        rightEye: CGPoint(x: 0.680, y: 0.500),
                        ear: CGPoint(x: 0.840, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 1.30,
                    pitchAngle: 0.45,
                    resourceName: "sunglasses-crayon-3d-profile-pitch-up",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.120, y: 0.500),
                        rightEye: CGPoint(x: 0.290, y: 0.500),
                        ear: CGPoint(x: 0.950, y: 0.500)
                    )
                ),
                StickerFaceView(
                    yawAngle: 1.30,
                    pitchAngle: -0.45,
                    resourceName: "sunglasses-crayon-3d-profile-pitch-down",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.120, y: 0.500),
                        rightEye: CGPoint(x: 0.290, y: 0.500),
                        ear: CGPoint(x: 0.950, y: 0.500)
                    )
                )
            ],
            faceViewYawSign: -1,
            faceViewPitchSign: 1,
            renderingMode: .rendered3DViews
        ),
        StickerDefinition(
            id: "sticker-ai-cap-crayon-3d", name: "蜡笔帽子 · 3D", category: .aiSticker,
            resourceName: "cap-crayon-3d-front", resourceExtension: "png",
            isFrameSequence: false, frameCount: 1, frameDuration: 1,
            faceAnchors: StickerFaceAnchors(
                leftEye: CGPoint(x: 0.300, y: 0.845),
                rightEye: CGPoint(x: 0.700, y: 0.845)
            ),
            faceViews: [
                StickerFaceView(
                    yawAngle: 0,
                    resourceName: "cap-crayon-3d-front",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.300, y: 0.845),
                        rightEye: CGPoint(x: 0.700, y: 0.845)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0.70,
                    resourceName: "cap-crayon-3d-three-quarter",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.400, y: 0.845),
                        rightEye: CGPoint(x: 0.760, y: 0.845)
                    )
                ),
                StickerFaceView(
                    yawAngle: 1.30,
                    resourceName: "cap-crayon-3d-profile",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.280, y: 0.845),
                        rightEye: CGPoint(x: 0.520, y: 0.845)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0,
                    pitchAngle: 0.45,
                    resourceName: "cap-crayon-3d-front-pitch-up",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.300, y: 0.845),
                        rightEye: CGPoint(x: 0.700, y: 0.845)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0,
                    pitchAngle: -0.45,
                    resourceName: "cap-crayon-3d-front-pitch-down",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.300, y: 0.845),
                        rightEye: CGPoint(x: 0.700, y: 0.845)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0.70,
                    pitchAngle: 0.45,
                    resourceName: "cap-crayon-3d-three-quarter-pitch-up",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.400, y: 0.845),
                        rightEye: CGPoint(x: 0.760, y: 0.845)
                    )
                ),
                StickerFaceView(
                    yawAngle: 0.70,
                    pitchAngle: -0.45,
                    resourceName: "cap-crayon-3d-three-quarter-pitch-down",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.400, y: 0.845),
                        rightEye: CGPoint(x: 0.760, y: 0.845)
                    )
                ),
                StickerFaceView(
                    yawAngle: 1.30,
                    pitchAngle: 0.45,
                    resourceName: "cap-crayon-3d-profile-pitch-up",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.280, y: 0.845),
                        rightEye: CGPoint(x: 0.520, y: 0.845)
                    )
                ),
                StickerFaceView(
                    yawAngle: 1.30,
                    pitchAngle: -0.45,
                    resourceName: "cap-crayon-3d-profile-pitch-down",
                    anchors: StickerFaceAnchors(
                        leftEye: CGPoint(x: 0.280, y: 0.845),
                        rightEye: CGPoint(x: 0.520, y: 0.845)
                    )
                )
            ],
            faceViewYawSign: -1,
            faceViewPitchSign: 1,
            renderingMode: .rendered3DViews
        ),
        StickerDefinition(
            id: "sticker-logo-hand-lettered", name: "logo", category: .logo,
            resourceName: "gifbloom-hand-lettered", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 6, frameDuration: 0.08
        ),
        StickerDefinition(
            id: "sticker-logo-doodle", name: "logo", category: .logo,
            resourceName: "gifbloom-doodle", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 6, frameDuration: 0.08
        ),
        StickerDefinition(
            id: "sticker-logo-crayon", name: "logo", category: .logo,
            resourceName: "gifbloom-crayon", resourceExtension: "gif",
            isFrameSequence: false, frameCount: 6, frameDuration: 0.08
        )
    ]

    /// The editor catalog excludes hidden AI stickers. Keep their definitions
    /// in `stickerCatalog` so older saved compositions can still render.
    public static let availableStickerCatalog = stickerCatalog.filter {
        $0.category != .aiSticker
    }

    public init() {}

    public static func stickerDefinition(for decorationID: String) -> StickerDefinition? {
        stickerCatalog.first { $0.id == decorationID }
    }

    public static func stickerName(for decorationID: String) -> String {
        stickerDefinition(for: decorationID)?.name ?? decorationID
    }

    public static func faceViewSelection(
        for decorationID: String,
        yaw: CGFloat?,
        pitch: CGFloat? = nil
    ) -> StickerFaceViewSelection? {
        guard let definition = stickerDefinition(for: decorationID),
              let views = definition.faceViews,
              !views.isEmpty else {
            return nil
        }
        let rawYaw = (yaw ?? 0).isFinite ? (yaw ?? 0) : 0
        let signedYaw = rawYaw * definition.faceViewYawSign
        let target = abs(signedYaw)
        let mirrored = signedYaw < 0
        let rawPitch = (pitch ?? 0).isFinite ? (pitch ?? 0) : 0
        let signedPitch = rawPitch * definition.faceViewPitchSign
        let pitchLevel = views
            .map(\StickerFaceView.pitchAngle)
            .min { abs($0 - signedPitch) < abs($1 - signedPitch) } ?? 0
        let pitchViews = views.filter { abs($0.pitchAngle - pitchLevel) < 0.0001 }
        guard !pitchViews.isEmpty else { return nil }
        guard pitchViews.count > 1 else {
            return StickerFaceViewSelection(first: pitchViews[0], second: pitchViews[0], blend: 0, isMirrored: mirrored)
        }
        if target <= pitchViews[0].yawAngle {
            return StickerFaceViewSelection(first: pitchViews[0], second: pitchViews[0], blend: 0, isMirrored: mirrored)
        }
        if target >= pitchViews[pitchViews.count - 1].yawAngle {
            let last = pitchViews[pitchViews.count - 1]
            return StickerFaceViewSelection(first: last, second: last, blend: 0, isMirrored: mirrored)
        }
        for index in 0..<(pitchViews.count - 1) {
            let first = pitchViews[index]
            let second = pitchViews[index + 1]
            guard target >= first.yawAngle, target <= second.yawAngle else { continue }
            let span = max(second.yawAngle - first.yawAngle, 0.001)
            let blend = min(max((target - first.yawAngle) / span, 0), 1)
            return StickerFaceViewSelection(first: first, second: second, blend: blend, isMirrored: mirrored)
        }
        return nil
    }

    /// 从内置 logo 贴纸中随机选取一个，用于一次导出的品牌水印。
    public static func randomLogoWatermark() -> ExportWatermark? {
        guard let logo = availableStickerCatalog.filter({ $0.category == .logo }).randomElement() else {
            return nil
        }
        return ExportWatermark(decorationID: logo.id)
    }

    /// 贴纸选择器使用的静态预览帧。
    public func previewImage(for decorationID: String) -> CGImage? {
        frames(for: decorationID)?.first
    }

    /// 贴纸选择器使用的帧序列预览。帧在进程内按贴纸 id 缓存，避免每次打开面板重复解码。
    public func previewFrames(for decorationID: String) -> [CGImage] {
        frames(for: decorationID) ?? []
    }

    /// Stable visible-art bounds for selection affordances, in the sticker's
    /// lower-left-origin image coordinates. Animated frames and alternate face
    /// views are unioned so the selection frame does not jitter during playback.
    public func selectionBounds(for decorationID: String) -> CGRect? {
        let cacheKey = decorationID as NSString
        Self.lock.lock()
        let cached = Self.stickerSelectionBoundsCache.object(forKey: cacheKey)?.rect
        Self.lock.unlock()
        if let cached { return cached }

        guard let definition = Self.stickerDefinition(for: decorationID) else { return nil }
        var candidates = frames(for: decorationID) ?? []
        for faceView in definition.faceViews ?? [] {
            guard let url = Self.stickerResourceURL(
                resourceName: faceView.resourceName,
                resourceExtension: definition.resourceExtension
            ),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                continue
            }
            candidates.append(image)
        }

        var visibleBounds: CGRect?
        for image in candidates {
            guard let imageBounds = Self.visibleBounds(in: image) else { continue }
            visibleBounds = visibleBounds.map { $0.union(imageBounds) } ?? imageBounds
        }

        if let visibleBounds {
            Self.lock.lock()
            Self.stickerSelectionBoundsCache.setObject(StickerSelectionBoundsBox(visibleBounds), forKey: cacheKey)
            Self.lock.unlock()
        }
        return visibleBounds
    }

    private static func visibleBounds(in image: CGImage) -> CGRect? {
        let maximumSampleSize: CGFloat = 256
        let scale = min(
            1,
            maximumSampleSize / CGFloat(max(image.width, image.height))
        )
        let sampledImage: CGImage
        if scale < 1 {
            let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
            let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let downsampled = context.makeImage() else { return nil }
            sampledImage = downsampled
        } else {
            sampledImage = image
        }

        guard let pixelBounds = AlphaSubjectBounds.visiblePixelBounds(in: sampledImage) else {
            return nil
        }
        // Expand by one sample pixel to retain antialiased edges after downsampling.
        let scaleX = CGFloat(image.width) / CGFloat(sampledImage.width)
        let scaleY = CGFloat(image.height) / CGFloat(sampledImage.height)
        let minX = max(0, pixelBounds.minX * scaleX - scaleX)
        let maxX = min(CGFloat(image.width), pixelBounds.maxX * scaleX + scaleX)
        let minY = max(0, CGFloat(image.height) - pixelBounds.maxY * scaleY - scaleY)
        let maxY = min(CGFloat(image.height), CGFloat(image.height) - pixelBounds.minY * scaleY + scaleY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 范围编辑器只需要少量采样帧，不为它解码整段高清 GIF。
    public static func previewThumbnail(for id: String, at time: TimeInterval,
                                        maxPixelSize: Int = 160) -> CGImage? {
        guard time.isFinite, let definition = stickerDefinition(for: id) else { return nil }
        if definition.renderingMode == .rendered3DModel {
            return Procedural3DStickerRenderer.image(for: id, yaw: 0, pixelSize: max(maxPixelSize, 1))
        }
        if let nativeEmoji = definition.nativeEmoji {
            return nativeEmojiImage(nativeEmoji, pixelSize: max(maxPixelSize, 64))
        }
        let index = min(max(Int(max(time, 0) / definition.frameDuration), 0), max(definition.frameCount - 1, 0))
        guard let url = stickerResourceURL(for: definition, frameIndex: index),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let frame = definition.isFrameSequence ? 0 : min(index, CGImageSourceGetCount(source) - 1)
        return CGImageSourceCreateThumbnailAtIndex(source, frame, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }

    /// Render one sticker at a requested preview yaw. The sticker picker uses
    /// this to compare the authored 2D views, the interpolated view renders,
    /// and the procedural 3D model through the same interaction.
    public func previewImage(
        for decorationID: String,
        yaw: CGFloat,
        pitch: CGFloat = 0,
        maxPixelSize: Int = 768
    ) -> CGImage? {
        let size = CGFloat(max(maxPixelSize, 64))
        guard let image = image(
            for: decorationID,
            canvas: CGRect(x: 0, y: 0, width: size, height: size),
            faceYaw: yaw,
            facePitch: pitch
        ) else {
            return nil
        }
        return Self.previewCIContext.createCGImage(image, from: image.extent)
    }

    /// 装饰 id 约定：frame-gold / corners / vignette / glow-soft / glow-orb / dust / wand-beam（矢量）
    /// 以及 sticker-*（Bundle 内的动图贴纸，需要时间参数）
    /// - Parameter localTime: 元素内时间（秒，从元素起始时间起算）
    /// - Parameter duration: 元素时长（秒），用于判断选定源区间是否需要循环
    /// - Parameter sourceStartTime: 源动画入点（秒）
    /// - Parameter sourceEndTime: 源动画出点（秒）
    public func image(
        for decorationID: String,
        canvas: CGRect,
        at localTime: TimeInterval = 0,
        duration: TimeInterval = 0,
        sourceStartTime: TimeInterval = 0,
        sourceEndTime: TimeInterval = .greatestFiniteMagnitude,
        playbackOffsetTime: TimeInterval = 0,
        playbackCount: Int? = nil,
        faceYaw: CGFloat? = nil,
        facePitch: CGFloat? = nil
    ) -> CIImage? {
        if decorationID.hasPrefix("sticker-") {
            return stickerImage(
                decorationID: decorationID,
                localTime: localTime,
                duration: duration,
                sourceStartTime: sourceStartTime,
                sourceEndTime: sourceEndTime,
                playbackOffsetTime: playbackOffsetTime,
                playbackCount: playbackCount,
                faceYaw: faceYaw,
                facePitch: facePitch
            )
        }
        let key = "\(decorationID)-\(Int(canvas.width))x\(Int(canvas.height))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let cg = draw(decorationID: decorationID, size: canvas.size) else { return nil }
        let ci = CIImage(cgImage: cg)
        cache.setObject(ci, forKey: key)
        return ci
    }

    // MARK: - 动图贴纸

    /// 加载贴纸帧序列（首次解码后缓存）；帧图 512x512 含透明
    private func frames(for decorationID: String) -> [CGImage]? {
        let cacheKey = decorationID as NSString
        Self.lock.lock()
        if let cached = Self.stickerFrameCache.object(forKey: cacheKey) {
            Self.lock.unlock()
            return cached.frames
        }
        Self.lock.unlock()

        guard let definition = Self.stickerDefinition(for: decorationID) else { return nil }
        var loaded: [CGImage] = []
        if let nativeEmoji = definition.nativeEmoji {
            guard let image = Self.nativeEmojiImage(nativeEmoji) else {
                Self.lock.lock()
                Self.stickerFrameCache.setObject(StickerFrameBox([]), forKey: cacheKey)
                Self.lock.unlock()
                return nil
            }
            loaded = [image]
        } else if definition.renderingMode == .rendered3DModel {
            guard let image = Procedural3DStickerRenderer.image(for: decorationID, yaw: 0) else {
                Self.lock.lock()
                Self.stickerFrameCache.setObject(StickerFrameBox([]), forKey: cacheKey)
                Self.lock.unlock()
                return nil
            }
            loaded = [image]
        } else if definition.isFrameSequence {
            loaded.reserveCapacity(definition.frameCount)
            for i in 0..<definition.frameCount {
                guard let url = Self.stickerResourceURL(for: definition, frameIndex: i),
                   let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    Self.lock.lock()
                    Self.stickerFrameCache.setObject(StickerFrameBox([]), forKey: cacheKey)
                    Self.lock.unlock()
                    return nil
                }
                loaded.append(img)
            }
        } else {
            guard let url = Self.stickerResourceURL(for: definition),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                Self.lock.lock()
                Self.stickerFrameCache.setObject(StickerFrameBox([]), forKey: cacheKey)
                Self.lock.unlock()
                return nil
            }

            let count = CGImageSourceGetCount(source)
            loaded.reserveCapacity(count)
            for index in 0..<count {
                guard let img = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                loaded.append(img)
            }
        }
        Self.lock.lock()
        let cost = loaded.reduce(0) { partial, image in
            partial + image.width * image.height * 4
        }
        Self.stickerFrameCache.setObject(StickerFrameBox(loaded), forKey: cacheKey, cost: cost)
        Self.lock.unlock()
        return loaded
    }

    /// Rasterize a Unicode emoji with the platform color emoji font. This
    /// keeps Apple artwork out of the app bundle while preserving the native
    /// appearance on iOS and macOS.
    private static func nativeEmojiImage(_ emoji: String, pixelSize: Int = 512) -> CGImage? {
        guard !emoji.isEmpty else { return nil }
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 420, nil)
        let attributedString = NSAttributedString(string: emoji, attributes: [
            .font: font
        ])
        let line = CTLineCreateWithAttributedString(attributedString)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let size = max(pixelSize, 64)
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let availableSize = CGFloat(size) * 0.82
        let scale = min(availableSize / bounds.width, availableSize / bounds.height)
        context.saveGState()
        context.translateBy(
            x: CGFloat(size) * 0.5 - bounds.midX * scale,
            y: CGFloat(size) * 0.5 - bounds.midY * scale
        )
        context.scaleBy(x: scale, y: scale)
        CTLineDraw(line, context)
        context.restoreGState()
        return context.makeImage()
    }

    /// 贴纸资源可能来自 Swift Package 的资源包，也可能来自 App target 的 Watermarks
    /// 目录。两套入口统一解析，避免预览、画布和导出各自使用不同路径。
    private static func stickerResourceURL(
        for definition: StickerDefinition,
        frameIndex: Int? = nil
    ) -> URL? {
        let name: String
        if definition.isFrameSequence, let frameIndex {
            name = String(format: definition.resourceName, frameIndex)
        } else {
            name = definition.resourceName
        }

        return stickerResourceURL(resourceName: name, resourceExtension: definition.resourceExtension)
    }

    private static func stickerResourceURL(resourceName: String, resourceExtension: String) -> URL? {
        let bundles = [Bundle.module, Bundle.main]
        for bundle in bundles {
            if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) {
                return url
            }
            if let url = bundle.url(
                forResource: resourceName,
                withExtension: resourceExtension,
                subdirectory: "Watermarks"
            ) {
                return url
            }
            if let url = bundle.url(
                forResource: resourceName,
                withExtension: resourceExtension,
                subdirectory: "GeneratedStickers/AI贴纸"
            ) {
                return url
            }
        }
        return nil
    }

    /// 按素材声明的单帧时长播放；由显式次数决定是否重复选定片段。
    private func stickerImage(
        decorationID: String,
        localTime: TimeInterval,
        duration: TimeInterval,
        sourceStartTime: TimeInterval,
        sourceEndTime: TimeInterval,
        playbackOffsetTime: TimeInterval,
        playbackCount: Int?,
        faceYaw: CGFloat?,
        facePitch: CGFloat?
    ) -> CIImage? {
        guard let definition = Self.stickerDefinition(for: decorationID) else { return nil }
        if definition.renderingMode == .rendered3DModel {
            guard let image = Procedural3DStickerRenderer.image(
                for: decorationID,
                yaw: faceYaw
            ) else { return nil }
            return CIImage(cgImage: image)
        }
        if definition.renderingMode != .standard,
           let selection = Self.faceViewSelection(for: decorationID, yaw: faceYaw, pitch: facePitch) {
            switch definition.renderingMode {
            case .multiView2D:
                let view = selection.nearestView
                guard let image = faceViewImage(named: view.resourceName, extension: definition.resourceExtension) else {
                    return nil
                }
                return selection.isMirrored ? mirrored(image) : image
            case .rendered3DViews:
                guard let first = faceViewImage(named: selection.first.resourceName, extension: definition.resourceExtension),
                      let second = faceViewImage(named: selection.second.resourceName, extension: definition.resourceExtension) else {
                    return nil
                }
                let firstImage = selection.isMirrored ? mirrored(first) : first
                let secondImage = selection.isMirrored ? mirrored(second) : second
                return blended(firstImage, secondImage, amount: selection.blend)
            case .rendered3DModel:
                return nil
            case .standard:
                break
            }
        }
        guard let frames = frames(for: decorationID), !frames.isEmpty else { return nil }
        let sourceDuration = max(definition.defaultDuration, 0.1)
        let sourceRange = SourcePlaybackRange(
            duration: sourceDuration,
            start: sourceStartTime,
            end: sourceEndTime
        )
        let elapsed = max(localTime, 0)
        let sourceTime = sourceRange.sourceTime(
            at: elapsed,
            phase: playbackOffsetTime,
            looping: playbackCount.map { $0 > 1 } ?? (duration > sourceRange.span + 0.001)
        )
        let frameIndex = min(
            max(Int((sourceTime / definition.frameDuration).rounded(.down)), 0),
            frames.count - 1
        )
        return CIImage(cgImage: frames[frameIndex])
    }

    private func faceViewImage(named name: String, extension fileExtension: String) -> CIImage? {
        let key = "\(name).\(fileExtension)" as NSString
        Self.lock.lock()
        let cached = Self.faceViewImageCache.object(forKey: key)
        Self.lock.unlock()
        if let cached { return CIImage(cgImage: cached) }
        guard let url = Self.stickerResourceURL(resourceName: name, resourceExtension: fileExtension),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        Self.lock.lock()
        Self.faceViewImageCache.setObject(image, forKey: key, cost: image.width * image.height * 4)
        Self.lock.unlock()
        return CIImage(cgImage: image)
    }

    private func mirrored(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let flipped = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        return flipped.transformed(by: CGAffineTransform(translationX: extent.minX + extent.maxX, y: 0))
    }

    private func blended(_ first: CIImage, _ second: CIImage, amount: CGFloat) -> CIImage {
        let t = min(max(amount, 0), 1)
        guard t > 0.001, t < 0.999 else { return t >= 0.999 ? second : first }
        func weighted(_ image: CIImage, by weight: CGFloat) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        }
        return weighted(first, by: 1 - t).applyingFilter(
            "CIAdditionCompositing",
            parameters: [kCIInputBackgroundImageKey: weighted(second, by: t)]
        )
    }

    private func draw(decorationID: String, size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        switch decorationID {
        case "frame-gold":
            drawFrame(ctx, size: size)
        case "corners":
            drawCorners(ctx, size: size)
        case "vignette":
            drawVignette(ctx, size: size)
        case "glow-soft":
            drawGlow(ctx, size: size, soft: true)
        case "glow-orb":
            drawGlow(ctx, size: size, soft: false)
        case "dust":
            drawDust(ctx, size: size)
        case "wand-beam":
            drawWandBeam(ctx, size: size)
        default:
            return nil
        }
        return ctx.makeImage()
    }

    // MARK: - 画框

    private func drawFrame(_ ctx: CGContext, size: CGSize) {
        let gold = CGColor(red: 0.87, green: 0.72, blue: 0.38, alpha: 1)
        let goldDeep = CGColor(red: 0.55, green: 0.42, blue: 0.18, alpha: 1)
        let frameW = min(size.width, size.height) * 0.045
        let rect = CGRect(x: frameW / 2, y: frameW / 2, width: size.width - frameW, height: size.height - frameW)

        ctx.setLineWidth(frameW)
        ctx.setStrokeColor(goldDeep)
        ctx.stroke(rect.insetBy(dx: frameW * 0.35, dy: frameW * 0.35))
        ctx.setStrokeColor(gold)
        ctx.stroke(rect)
        // 内侧细金线
        ctx.setLineWidth(frameW * 0.25)
        ctx.setStrokeColor(gold)
        ctx.stroke(rect.insetBy(dx: frameW * 0.75, dy: frameW * 0.75))
    }

    private func drawCorners(_ ctx: CGContext, size: CGSize) {
        let gold = CGColor(red: 0.87, green: 0.72, blue: 0.38, alpha: 1)
        let arm = min(size.width, size.height) * 0.16
        let inset = min(size.width, size.height) * 0.045
        let width: CGFloat = min(size.width, size.height) * 0.02
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(gold)
        let points: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: inset, y: size.height - inset), CGPoint(x: inset + arm, y: size.height - inset),
             CGPoint(x: inset, y: size.height - inset), CGPoint(x: inset, y: size.height - inset - arm)),
            (CGPoint(x: size.width - inset, y: size.height - inset), CGPoint(x: size.width - inset - arm, y: size.height - inset),
             CGPoint(x: size.width - inset, y: size.height - inset), CGPoint(x: size.width - inset, y: size.height - inset - arm)),
            (CGPoint(x: inset, y: inset), CGPoint(x: inset + arm, y: inset),
             CGPoint(x: inset, y: inset), CGPoint(x: inset, y: inset + arm)),
            (CGPoint(x: size.width - inset, y: inset), CGPoint(x: size.width - inset - arm, y: inset),
             CGPoint(x: size.width - inset, y: inset), CGPoint(x: size.width - inset, y: inset + arm))
        ]
        for (h1, h2, v1, v2) in points {
            ctx.move(to: h1); ctx.addLine(to: h2)
            ctx.move(to: v1); ctx.addLine(to: v2)
        }
        ctx.strokePath()
    }

    // MARK: - 暗角

    private func drawVignette(_ ctx: CGContext, size: CGSize) {
        let colors = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.45),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.72]
        ) else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.72
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: radius * 0.35, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: - 光效

    private func drawGlow(_ ctx: CGContext, size: CGSize, soft: Bool) {
        let colors = [
            CGColor(red: 1.0, green: 0.92, blue: 0.62, alpha: 0.9),
            CGColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 0.18),
            CGColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 0)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.45, 1]
        ) else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * (soft ? 0.55 : 0.3)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: - 飘尘

    private func drawDust(_ ctx: CGContext, size: CGSize) {
        var generator = SystemRandomNumberGenerator()
        let count = 60
        for _ in 0..<count {
            let x = CGFloat.random(in: 0...size.width, using: &generator)
            let y = CGFloat.random(in: 0...size.height, using: &generator)
            let r = CGFloat.random(in: 0.5...2.2, using: &generator)
            let alpha = CGFloat.random(in: 0.12...0.5, using: &generator)
            ctx.setFillColor(CGColor(red: 1, green: 0.94, blue: 0.75, alpha: alpha))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - 魔杖光束

    private func drawWandBeam(_ ctx: CGContext, size: CGSize) {
        // 右上角斜向金色光束
        ctx.saveGState()
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: -CGFloat.pi / 5)
        let colors = [
            CGColor(red: 1, green: 0.92, blue: 0.62, alpha: 0.55),
            CGColor(red: 1, green: 0.92, blue: 0.62, alpha: 0)
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) else { return }
        let beamRect = CGRect(x: -size.width * 0.45, y: -4, width: size.width * 0.9, height: 8)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: beamRect.minX, y: 0),
            end: CGPoint(x: beamRect.maxX, y: 0),
            options: []
        )
        ctx.restoreGState()
        // 中心星芒点
        let sparkleColors = [
            CGColor(red: 1, green: 1, blue: 0.85, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0.85, alpha: 0)
        ] as CFArray
        if let sparkle = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sparkleColors, locations: [0, 1]) {
            ctx.drawRadialGradient(
                sparkle, startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: min(size.width, size.height) * 0.12,
                options: []
            )
        }
        ctx.restoreGState()
    }
}
