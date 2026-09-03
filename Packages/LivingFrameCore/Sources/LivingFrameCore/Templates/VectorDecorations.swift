import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public enum StickerCategory: String, Equatable, Sendable {
    case doodle
}

public struct StickerDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: StickerCategory
    public let resourceName: String
    public let resourceExtension: String
    public let isFrameSequence: Bool
    public let frameCount: Int

    public var defaultDuration: TimeInterval {
        Double(frameCount) * 0.1
    }

    public init(
        id: String,
        name: String,
        category: StickerCategory,
        resourceName: String,
        resourceExtension: String,
        isFrameSequence: Bool,
        frameCount: Int
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.resourceName = resourceName
        self.resourceExtension = resourceExtension
        self.isFrameSequence = isFrameSequence
        self.frameCount = frameCount
    }
}

/// 装饰绘制：CoreGraphics 代码生成 + 动图贴纸（PNG 帧序列，Bundle 内资源）
/// 体积 0 的矢量装饰 vs 位图贴纸双平台复用
public struct DecorationRenderer {
    private let cache = NSCache<NSString, CIImage>()
    private static let lock = NSLock()
    /// 动图贴纸帧缓存。NSCache 会在内存紧张时自动回收，避免未来增加贴纸后永久持有所有帧。
    private static let stickerFrameCache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 8
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func clearSharedCaches() {
        lock.lock()
        stickerFrameCache.removeAllObjects()
        lock.unlock()
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
            id: "sticker-doodle-summer", name: "summer", category: .doodle,
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
        )
    ]

    public init() {}

    public static func stickerDefinition(for decorationID: String) -> StickerDefinition? {
        stickerCatalog.first { $0.id == decorationID }
    }

    public static func stickerName(for decorationID: String) -> String {
        stickerDefinition(for: decorationID)?.name ?? decorationID
    }

    /// 贴纸选择器使用的静态预览帧。
    public func previewImage(for decorationID: String) -> CGImage? {
        frames(for: decorationID)?.first
    }

    /// 贴纸选择器使用的帧序列预览。帧在进程内按贴纸 id 缓存，避免每次打开面板重复解码。
    public func previewFrames(for decorationID: String) -> [CGImage] {
        frames(for: decorationID) ?? []
    }

    /// 装饰 id 约定：frame-gold / corners / vignette / glow-soft / glow-orb / dust / wand-beam（矢量）
    /// 以及 sticker-*（Bundle 内的动图贴纸，需要时间参数）
    /// - Parameter localTime: 元素内时间（秒，从元素起始时间起算）
    /// - Parameter duration: 元素时长（秒），动图贴纸把全部帧铺满整个时间段
    public func image(for decorationID: String, canvas: CGRect, at localTime: TimeInterval = 0, duration: TimeInterval = 0) -> CIImage? {
        if decorationID.hasPrefix("sticker-") {
            return stickerImage(decorationID: decorationID, localTime: localTime, duration: duration)
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
            return cached.map { $0 as! CGImage }
        }
        Self.lock.unlock()

        guard let definition = Self.stickerDefinition(for: decorationID) else { return nil }
        var loaded: [CGImage] = []
        loaded.reserveCapacity(definition.frameCount)

        if definition.isFrameSequence {
            for i in 0..<definition.frameCount {
                guard let url = Bundle.module.url(
                    forResource: String(format: definition.resourceName, i),
                    withExtension: definition.resourceExtension
                ), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    Self.lock.lock()
                    Self.stickerFrameCache.setObject([] as NSArray, forKey: cacheKey)
                    Self.lock.unlock()
                    return nil
                }
                loaded.append(img)
            }
        } else {
            guard let url = Bundle.module.url(
                forResource: definition.resourceName,
                withExtension: definition.resourceExtension
            ), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                Self.lock.lock()
                Self.stickerFrameCache.setObject([] as NSArray, forKey: cacheKey)
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
        Self.stickerFrameCache.setObject(loaded as NSArray, forKey: cacheKey, cost: cost)
        Self.lock.unlock()
        return loaded
    }

    /// 按固定 0.1s/帧播放，拉长时间轴时帧循环补满（不减速）：
    /// 默认时长=一帧循环（9 帧×0.1s=0.9s）时即"播放一次"
    private func stickerImage(decorationID: String, localTime: TimeInterval, duration: TimeInterval) -> CIImage? {
        guard let frames = frames(for: decorationID), !frames.isEmpty else { return nil }
        let frameIndex = Int((max(localTime, 0) / 0.1).rounded(.down)) % frames.count
        return CIImage(cgImage: frames[frameIndex])
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
