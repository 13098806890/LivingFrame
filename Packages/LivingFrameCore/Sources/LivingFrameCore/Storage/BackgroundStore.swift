import AVFoundation
import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 用户导入的背景媒体元数据。图片与 GIF/APNG 都以原始数据落盘，动态帧按时间按需解码。
public enum BackgroundMediaType: String, Codable, Equatable, Sendable {
    case image
    case video
}

public struct BackgroundMediaItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let frameCount: Int
    public let duration: TimeInterval
    public let width: Int
    public let height: Int
    public let createdAt: Date
    public let mediaType: BackgroundMediaType

    /// Live Photo 的配对视频、视频背景和 GIF/APNG 都需要按时间取帧。
    public var isAnimated: Bool { mediaType == .video || frameCount > 1 }

    public init(
        id: String,
        name: String,
        frameCount: Int,
        duration: TimeInterval,
        width: Int,
        height: Int,
        createdAt: Date,
        mediaType: BackgroundMediaType = .image
    ) {
        self.id = id
        self.name = name
        self.frameCount = frameCount
        self.duration = duration
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.mediaType = mediaType
    }
}

/// 背景图片存储：用户相册图片与 App 预置图片统一存于 Documents/Library/Backgrounds/
public struct BackgroundStore {
    public static let shared = BackgroundStore()

    public let rootURL: URL
    /// 解码后的背景图内存缓存：渲染每帧都会 loadImage，避免反复解码 JPEG
    private static let imageCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 16
        return cache
    }()
    private static let frameCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()
    private static let orientationContext = CIContext(options: [.cacheIntermediates: false])
    /// 预置背景列表（文件名 → 显示名）
    public let presets: [(fileName: String, title: String)] = [
        ("preset-starfield", NSLocalizedString("星空", comment: "Preset background")),
        ("preset-aurora", NSLocalizedString("极光", comment: "Preset background")),
        ("preset-ember", NSLocalizedString("余烬", comment: "Preset background")),
        ("preset-blossom", NSLocalizedString("花影", comment: "Preset background")),
        ("preset-wizard", NSLocalizedString("魔法", comment: "Preset background")),
        ("preset-sunset", NSLocalizedString("暮色", comment: "Preset background")),
        ("preset-lines", NSLocalizedString("横线", comment: "Preset background")),
        ("preset-grid", NSLocalizedString("网格", comment: "Preset background")),
        ("preset-diagonal", NSLocalizedString("斜线", comment: "Preset background")),
        ("preset-mosaic", NSLocalizedString("马赛克", comment: "Preset background"))
    ]

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = documents.appendingPathComponent("Library/Backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        generatePresetsIfNeeded()
    }

    public func fileURL(named name: String) -> URL {
        rootURL.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    /// 新导入媒体保留自身扩展名；旧工程仍可通过 `fileURL` 找到 .jpg 文件。
    public func mediaURL(named name: String) -> URL {
        let extensions = ["mov", "mp4", "m4v", "gif", "png", "heic", "heif", "jpeg", "jpg"]
        for fileExtension in extensions {
            let url = rootURL.appendingPathComponent(name).appendingPathExtension(fileExtension)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return fileURL(named: name)
    }

    /// 保存用户选择的背景图
    @discardableResult
    public func saveUserImage(_ data: Data, preferredFileExtension: String? = nil) -> String? {
        let fileName = "user-\(UUID().uuidString)"
        let fileExtension = imageFileExtension(for: data, preferred: preferredFileExtension)
        let url = rootURL.appendingPathComponent(fileName).appendingPathExtension(fileExtension)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        Self.imageCache.removeObject(forKey: fileName as NSString)
        return fileName
    }

    /// Live Photo 使用配对 MOV 导入，不能当作静态照片数据保存。
    @discardableResult
    public func saveUserVideo(_ data: Data, preferredFileExtension: String? = nil) -> String? {
        let fileName = "user-\(UUID().uuidString)"
        let allowed = ["mov", "mp4", "m4v"]
        let requested = preferredFileExtension?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let fileExtension = requested.flatMap { allowed.contains($0) ? $0 : nil } ?? "mov"
        let url = rootURL.appendingPathComponent(fileName).appendingPathExtension(fileExtension)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        Self.imageCache.removeObject(forKey: fileName as NSString)
        return fileName
    }

    /// 返回用户已导入的背景媒体，最新导入的排在前面。
    public func allUserMedia() -> [BackgroundMediaItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            guard id.hasPrefix("user-") else { return nil }
            let dates = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let createdAt = dates?.creationDate ?? dates?.contentModificationDate ?? .distantPast
            if isVideo(url: url) {
                let asset = AVURLAsset(url: url)
                let duration = max(CMTimeGetSeconds(asset.duration), 0.1)
                let naturalSize = asset.tracks(withMediaType: .video).first?.naturalSize ?? .zero
                let transform = asset.tracks(withMediaType: .video).first?.preferredTransform ?? .identity
                let size = naturalSize.applying(transform)
                return BackgroundMediaItem(
                    id: id, name: id, frameCount: max(Int((duration * 30).rounded()), 1), duration: duration,
                    width: Int(abs(size.width)), height: Int(abs(size.height)), createdAt: createdAt, mediaType: .video
                )
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let frameCount = max(CGImageSourceGetCount(source), 1)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let duration = frameDurations(source: source).reduce(0, +)
            return BackgroundMediaItem(
                id: id,
                name: id,
                frameCount: frameCount,
                duration: max(duration, frameCount > 1 ? 0.1 : 0),
                width: width,
                height: height,
                createdAt: createdAt,
                mediaType: .image
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// 加载背景图（图片不存在时返回 nil）；带内存缓存（NSCache 线程安全）
    public func loadImage(named name: String) -> CGImage? {
        let key = name as NSString
        if let cached = Self.imageCache.object(forKey: key) { return cached }
        let url = mediaURL(named: name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let oriented = applyingOrientation(to: image, source: source, index: 0)
        Self.imageCache.setObject(oriented, forKey: key)
        return oriented
    }

    /// 按媒体时间加载一帧。静态图片始终返回第一帧，GIF/APNG 按自身时长循环。
    public func loadFrame(named name: String, at time: TimeInterval) -> CGImage? {
        if let cached = Self.imageCache.object(forKey: name as NSString) {
            return cached
        }
        let url = mediaURL(named: name)
        if isVideo(url: url) { return loadVideoFrame(named: name, url: url, at: time) }
        guard let source = imageSource(named: name) else { return nil }
        let count = max(CGImageSourceGetCount(source), 1)
        guard count > 1 else { return loadImage(named: name) }
        let durations = frameDurations(source: source)
        let total = max(durations.reduce(0, +), 0.1)
        let boundedTime = time.isFinite ? max(time, 0).truncatingRemainder(dividingBy: total) : 0
        var elapsed: TimeInterval = 0
        var selectedIndex = 0
        for index in 0..<count {
            elapsed += durations[index]
            if boundedTime < elapsed {
                selectedIndex = index
                break
            }
        }
        let key = "\(name)-\(selectedIndex)" as NSString
        if let cached = Self.frameCache.object(forKey: key) { return cached }
        guard let image = CGImageSourceCreateImageAtIndex(source, selectedIndex, nil) else { return nil }
        let oriented = applyingOrientation(to: image, source: source, index: selectedIndex)
        Self.frameCache.setObject(oriented, forKey: key)
        return oriented
    }

    public func media(named name: String) -> BackgroundMediaItem? {
        allUserMedia().first { $0.id == name }
    }

    private func imageSource(named name: String) -> CGImageSource? {
        let url = mediaURL(named: name)
        return CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    private func isVideo(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private func imageFileExtension(for data: Data, preferred: String?) -> String {
        let allowed = Set(["jpg", "jpeg", "png", "gif", "heic", "heif"])
        let requested = preferred?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let requested, allowed.contains(requested) { return requested }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(source),
           let preferredExtension = UTType(type as String)?.preferredFilenameExtension,
           allowed.contains(preferredExtension.lowercased()) {
            return preferredExtension.lowercased()
        }
        return "jpg"
    }

    private func applyingOrientation(to image: CGImage, source: CGImageSource, index: Int) -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard rawOrientation != 1 else { return image }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(rawOrientation))
        return Self.orientationContext.createCGImage(oriented, from: oriented.extent) ?? image
    }

    private func loadVideoFrame(named name: String, url: URL, at time: TimeInterval) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let duration = max(CMTimeGetSeconds(asset.duration), 0.1)
        let bounded = time.isFinite ? max(time, 0).truncatingRemainder(dividingBy: duration) : 0
        let frameIndex = Int((bounded * 30).rounded(.down))
        let key = "\(name)-video-\(frameIndex)" as NSString
        if let cached = Self.frameCache.object(forKey: key) { return cached }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let frame = try? generator.copyCGImage(
            at: CMTime(seconds: bounded, preferredTimescale: 600),
            actualTime: nil
        ) else { return nil }
        Self.frameCache.setObject(frame, forKey: key)
        return frame
    }

    private func frameDurations(source: CGImageSource) -> [TimeInterval] {
        let count = max(CGImageSourceGetCount(source), 1)
        return (0..<count).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let unclamped = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? 0
            let clamped = (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
            let duration = max(unclamped, clamped)
            return duration > 0.01 ? duration : 0.1
        }
    }

    // MARK: - 预置图片（程序化生成）

    /// 首次启动时生成预置背景 PNG
    private func generatePresetsIfNeeded() {
        for (fileName, _) in presets {
            let url = fileURL(named: fileName)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            let image = presetImage(fileName: fileName)
            guard let image else { continue }
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    /// 按名称绘制预置背景（1080×1440 竖版画布）
    private func presetImage(fileName: String) -> CGImage? {
        let width = 1080
        let height = 1440
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        switch fileName {
        case "preset-starfield":
            drawStarfield(context, width: width, height: height)
        case "preset-aurora":
            drawAurora(context, width: width, height: height)
        case "preset-ember":
            drawEmber(context, width: width, height: height)
        case "preset-blossom":
            drawBlossom(context, width: width, height: height)
        case "preset-wizard":
            drawWizard(context, width: width, height: height)
        case "preset-sunset":
            drawSunset(context, width: width, height: height)
        case "preset-lines":
            drawLines(context, width: width, height: height)
        case "preset-grid":
            drawGrid(context, width: width, height: height)
        case "preset-diagonal":
            drawDiagonal(context, width: width, height: height)
        case "preset-mosaic":
            drawMosaic(context, width: width, height: height)
        default:
            drawStarfield(context, width: width, height: height)
        }
        return context.makeImage()
    }

    private func drawDiagonal(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.96, 0.96, 0.98), (0.90, 0.90, 0.95)])
        context.setStrokeColor(red: 0.72, green: 0.72, blue: 0.78, alpha: 1)
        context.setLineWidth(2)
        let spacing: CGFloat = 72
        let diagonal = sqrt(CGFloat(width * width + height * height))
        for offset in stride(from: -diagonal, through: diagonal, by: spacing) {
            context.move(to: CGPoint(x: CGFloat(width) + offset, y: 0))
            context.addLine(to: CGPoint(x: offset, y: CGFloat(height)))
        }
        context.strokePath()
    }

    private func drawMosaic(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.97, 0.97, 0.99), (0.92, 0.92, 0.96)])
        let cell: CGFloat = 96
        var row = 0
        var y: CGFloat = 0
        while y < CGFloat(height) {
            var x: CGFloat = (row % 2 == 0) ? 0 : -cell / 2
            while x < CGFloat(width) {
                let rect = CGRect(x: x, y: y, width: cell, height: cell)
                if (Int(x / cell) + row) % 2 == 0 {
                    context.setFillColor(red: 0.85, green: 0.85, blue: 0.90, alpha: 1)
                } else {
                    context.setFillColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1)
                }
                context.fill(rect)
                x += cell
            }
            row += 1
            y += cell
        }
    }

    private func drawLines(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.96, 0.96, 0.98), (0.90, 0.90, 0.95)])
        context.setStrokeColor(red: 0.72, green: 0.72, blue: 0.78, alpha: 1)
        context.setLineWidth(2)
        for y in stride(from: 0, through: height, by: 72) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()
    }

    private func drawGrid(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.96, 0.96, 0.98), (0.90, 0.90, 0.95)])
        context.setStrokeColor(red: 0.72, green: 0.72, blue: 0.78, alpha: 1)
        context.setLineWidth(1)
        for x in stride(from: 0, through: width, by: 72) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, through: height, by: 72) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()
    }

    private func drawStarfield(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.02, 0.02, 0.08), (0.10, 0.08, 0.22)])
        var seed: UInt64 = 42
        for _ in 0..<140 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = CGFloat(seed % UInt64(width))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let y = CGFloat(seed % UInt64(height))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let size = CGFloat(seed % 5) + 1
            let alpha = 0.3 + CGFloat(seed % 70) / 100
            context.setFillColor(red: 0.9, green: 0.85, blue: 0.7, alpha: alpha)
            context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
        }
    }

    private func drawAurora(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.02, 0.05, 0.12), (0.04, 0.10, 0.20)])
        let bands: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.15, 0.20, 0.55, 0.55), (0.10, 0.55, 0.45, 0.50), (0.45, 0.15, 0.55, 0.45)
        ]
        for (i, band) in bands.enumerated() {
            let bandY = CGFloat(height) * (0.25 + 0.22 * CGFloat(i))
            context.setBlendMode(.screen)
            context.setFillColor(red: band.0, green: band.1, blue: band.2, alpha: band.3)
            for x in stride(from: -50, through: width + 50, by: 40) {
                let h = 120 + CGFloat(x % 200)
                context.fill(CGRect(x: CGFloat(x), y: bandY - h / 2, width: 60, height: h))
            }
        }
    }

    private func drawEmber(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.10, 0.02, 0.03), (0.05, 0.01, 0.02)])
        var seed: UInt64 = 7
        for _ in 0..<90 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = CGFloat(seed % UInt64(width))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let y = CGFloat(seed % UInt64(height))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let size = CGFloat(seed % 12) + 4
            let warm: CGFloat = CGFloat(seed % 30) / 30
            context.setFillColor(red: 0.9, green: 0.4 + warm, blue: 0.1, alpha: 0.7)
            context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
        }
    }

    private func drawBlossom(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.30, 0.22, 0.28), (0.16, 0.10, 0.16)])
        var seed: UInt64 = 99
        for _ in 0..<40 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = CGFloat(seed % UInt64(width))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let y = CGFloat(seed % UInt64(height))
            let r: CGFloat = 18 + CGFloat(seed % 30)
            drawFlower(context, center: CGPoint(x: x, y: y), radius: r,
                       color: (0.9, 0.7, 0.8), alpha: 0.5)
        }
    }

    private func drawFlower(_ context: CGContext, center: CGPoint, radius: CGFloat, color: (CGFloat, CGFloat, CGFloat), alpha: CGFloat) {
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: alpha)
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3
            let petal = CGRect(
                x: center.x + cos(angle) * radius - radius / 3,
                y: center.y + sin(angle) * radius - radius / 3,
                width: radius * 2 / 3, height: radius * 2 / 3
            )
            context.fillEllipse(in: petal)
        }
        context.setFillColor(red: 1, green: 0.9, blue: 0.5, alpha: alpha + 0.2)
        context.fillEllipse(in: CGRect(x: center.x - radius / 5, y: center.y - radius / 5, width: radius * 2 / 5, height: radius * 2 / 5))
    }

    private func drawWizard(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.10, 0.05, 0.25), (0.02, 0.02, 0.10)])
        var seed: UInt64 = 2024
        for _ in 0..<60 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = CGFloat(seed % UInt64(width))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let y = CGFloat(seed % UInt64(height))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let size = CGFloat(seed % 10) + 3
            let isGold = seed % 3 == 0
            context.setFillColor(red: isGold ? 0.9 : 0.55, green: isGold ? 0.75 : 0.48, blue: isGold ? 0.36 : 0.96, alpha: 0.6)
            context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
        }
    }

    private func drawSunset(_ context: CGContext, width: Int, height: Int) {
        fill(context, gradient: [(0.45, 0.15, 0.10), (0.95, 0.55, 0.25)])
        context.setFillColor(red: 0.99, green: 0.85, blue: 0.6, alpha: 0.9)
        context.fillEllipse(in: CGRect(
            x: CGFloat(width) / 2 - 130, y: CGFloat(height) * 0.62 - 130, width: 260, height: 260
        ))
    }

    private func fill(_ context: CGContext, gradient stops: [(CGFloat, CGFloat, CGFloat)]) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = stops.map { CGColor(colorSpace: colorSpace, components: [$0.0, $0.1, $0.2, 1])! } as CFArray
        let locations: [CGFloat] = (0..<stops.count).map { CGFloat($0) / CGFloat(max(stops.count - 1, 1)) }
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations)!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: CGFloat(context.height)),
            options: []
        )
    }
}
