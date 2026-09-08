import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 磁盘素材库：管理抠图素材的 PNG 序列目录（Documents/Library/Clips，持久保存）
public final class FrameCache {
    public static let shared = FrameCache()

    private let rootURL: URL
    private let registryLock = NSLock()
    private var registered: [String: SegmentedClip] = [:]
    /// 预览帧解码缓存（避免每帧重复磁盘解码导致素材库卡顿）
    private let frameLock = NSLock()
    private var frameCache: [String: CGImage] = [:]
    /// LRU 淘汰顺序（队首 = 最久未使用）。整表清空会导致多素材循环播放时频繁重解码
    private var frameOrder: [String] = []
    private var frameCacheCost = 0
    /// 预览缓存最多保留约 96MB，避免多素材播放时无限增长。
    private let frameCacheMaxCost = 96 * 1024 * 1024
    private let frameCacheMaxCount = 256
    /// 素材占用空间缓存（clipID → bytes）
    private var clipSizes: [String: Int64] = [:]
    /// 清单写入串行化，避免连续修改素材属性时出现旧状态覆盖新状态。
    private let manifestQueue = DispatchQueue(label: "livingframe.frame-cache.manifest", qos: .utility)

    private init() {
        rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library/Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func makeClipFolder(id: String) throws -> URL {
        let url = rootURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func register(_ clip: SegmentedClip) {
        registerInMemory(clip)
        persistManifest(for: clip)
    }

    /// 更新内存状态并异步保存清单，适合编辑器中的属性修改。
    /// UI 不应因为写入 clip.json 而等待磁盘。
    public func registerInBackground(_ clip: SegmentedClip) {
        registerInMemory(clip)
        guard let data = manifestData(for: clip) else { return }
        let url = manifestURL(for: clip.id)
        manifestQueue.async {
            try? data.write(to: url)
        }
    }

    /// Registers a restored clip for the current process without rewriting the manifest.
    /// UI fallback paths may call this when the AppState has the clip but the in-memory
    /// registry has not been repopulated yet.
    public func registerInMemory(_ clip: SegmentedClip) {
        registryLock.lock()
        registered[clip.id] = clip
        registryLock.unlock()
    }

    public func clip(id: String) -> SegmentedClip? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registered[id]
    }

    /// 带缓存的帧解码（预览/渲染共用，超出容量淘汰最久未使用）
    public func cachedFrame(for clip: SegmentedClip, index: Int) -> CGImage? {
        let key = "\(clip.id):\(index)"
        frameLock.lock()
        defer { frameLock.unlock() }
        return hitOrLoad(key: key) { clip.loadFrame(index: index) }
    }

    /// 低分辨率缩略帧解码（素材库/选择器预览用，直接按目标尺寸解码，省去全尺寸解码）
    public func cachedThumbnail(for clip: SegmentedClip, index: Int, maxPixelSize: CGFloat) -> CGImage? {
        let key = thumbnailKey(clip: clip, index: index, maxPixelSize: maxPixelSize)
        frameLock.lock()
        defer { frameLock.unlock() }
        return hitOrLoad(key: key) {
            let url = clip.frameURL(index: index) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }
    }

    /// Releases decoded frame pixels while preserving clip registrations and all
    /// source files on disk. Export calls this before allocating full-size output
    /// buffers so editor preview frames do not contribute to the export peak.
    public func purgeDecodedFrames() {
        frameLock.lock()
        frameCache.removeAll(keepingCapacity: false)
        frameOrder.removeAll(keepingCapacity: false)
        frameCacheCost = 0
        frameLock.unlock()
    }

    /// 命中返回并标记最近使用；未命中则加载入缓存（超容量淘汰最久未使用的一条）
    private func hitOrLoad(key: String, load: () -> CGImage?) -> CGImage? {
        if let image = frameCache[key] {
            touch(key)
            return image
        }
        guard let image = load() else { return nil }
        insert(image, forKey: key)
        return image
    }

    private func insert(_ image: CGImage, forKey key: String) {
        if let old = frameCache[key] {
            frameCacheCost -= imageCost(old)
        }
        frameCache[key] = image
        frameOrder.removeAll { $0 == key }
        frameOrder.append(key)
        frameCacheCost += imageCost(image)
        while frameOrder.count > frameCacheMaxCount || frameCacheCost > frameCacheMaxCost {
            guard let evicted = frameOrder.first else { break }
            frameOrder.removeFirst()
            if let image = frameCache.removeValue(forKey: evicted) {
                frameCacheCost -= imageCost(image)
            }
        }
    }

    private func imageCost(_ image: CGImage) -> Int {
        max(image.width * image.height * 4, 1)
    }

    private func thumbnailKey(clip: SegmentedClip, index: Int, maxPixelSize: CGFloat) -> String {
        "\(clip.id):\(index):thumb\(Int(maxPixelSize))"
    }

    private func touch(_ key: String) {
        if let index = frameOrder.firstIndex(of: key) {
            frameOrder.remove(at: index)
            frameOrder.append(key)
        }
    }

    /// 重新扫描磁盘，恢复所有素材注册（启动时调用）
    public func reload() {
        var loaded: [String: SegmentedClip] = [:]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        ) else {
            registryLock.lock()
            registered.removeAll()
            registryLock.unlock()
            return
        }
        for dir in entries where dir.hasDirectoryPath && dir.lastPathComponent != ".trash" {
            let id = dir.lastPathComponent
            guard let data = try? Data(contentsOf: manifestURL(for: id)),
                  let manifest = try? JSONDecoder().decode(ClipManifest.self, from: data) else { continue }
            let audioURL = manifest.audioFilename.map { dir.appendingPathComponent($0) }
            loaded[id] = SegmentedClip(
                id: manifest.id,
                name: manifest.name,
                fps: manifest.fps,
                frameCount: manifest.frameCount,
                width: manifest.width,
                height: manifest.height,
                folderURL: dir,
                audioURL: audioURL,
                edgeStyle: manifest.edgeStyle,
                edgeLineStyle: manifest.edgeLineStyle,
                edgeThickness: manifest.edgeThickness,
                edgeColorHex: manifest.edgeColorHex,
                stickerStyle: manifest.stickerStyle,
                playbackSpeed: manifest.playbackSpeed,
                excludedFrames: Set(manifest.excludedFrames)
            )
        }
        registryLock.lock()
        registered = loaded
        registryLock.unlock()
    }

    public func allClips() -> [SegmentedClip] {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registered.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func removeClip(id: String) {
        removeClipFromMemory(id: id)
        deleteClipFolder(id: id)
    }

    /// 立即释放注册信息和解码缓存，磁盘目录放到后台删除，避免素材库主线程卡顿。
    ///
    /// 删除素材时列表和详情页应先完成响应；素材目录通常包含大量 PNG，
    /// FileManager.removeItem 可能持续数百毫秒甚至更久，不能阻塞 SwiftUI 交互。
    public func removeClipInBackground(id: String) {
        removeClipFromMemory(id: id)
        let folderURL = rootURL.appendingPathComponent(id)
        let trashURL = quarantineClipFolder(id: id)
        // 与异步清单写入共用串行队列，避免“删除目录”和最后一次属性保存互相覆盖。
        manifestQueue.async {
            try? FileManager.default.removeItem(at: trashURL ?? folderURL)
        }
    }

    private func removeClipFromMemory(id: String) {
        registryLock.lock()
        registered[id] = nil
        registryLock.unlock()
        frameLock.lock()
        clipSizes[id] = nil
        // 清理该素材的解码缓存，避免残留占用内存
        let prefix = id + ":"
        let keysToRemove = frameCache.keys.filter { $0.hasPrefix(prefix) }
        for key in keysToRemove {
            if let image = frameCache.removeValue(forKey: key) {
                frameCacheCost -= imageCost(image)
            }
        }
        frameOrder.removeAll { $0.hasPrefix(prefix) }
        frameLock.unlock()
    }

    private func deleteClipFolder(id: String) {
        manifestQueue.sync {
            try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(id))
        }
    }

    /// 先把目录原子移动到隐藏回收区，再异步删除内容。
    /// 即使 App 在后台删除前被终止，启动扫描也不会把已删除素材恢复出来。
    private func quarantineClipFolder(id: String) -> URL? {
        manifestQueue.sync {
            let fileManager = FileManager.default
            let sourceURL = rootURL.appendingPathComponent(id)
            guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
            let trashRoot = rootURL.appendingPathComponent(".trash", isDirectory: true)
            try? fileManager.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let destinationURL = trashRoot.appendingPathComponent("\(id)-\(UUID().uuidString)")
            guard (try? fileManager.moveItem(at: sourceURL, to: destinationURL)) != nil else {
                return nil
            }
            return destinationURL
        }
    }

    /// 素材占用磁盘空间（缓存计算，删除素材时失效）
    public func clipSizeBytes(_ clip: SegmentedClip) -> Int64 {
        frameLock.lock()
        defer { frameLock.unlock() }
        if let size = clipSizes[clip.id] { return size }
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: clip.folderURL, includingPropertiesForKeys: keys
        ) {
            for case let url as URL in enumerator {
                if let values = try? url.resourceValues(forKeys: Set(keys)),
                   values.isDirectory != true,
                   let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }
        clipSizes[clip.id] = total
        return total
    }

    public func removeAll() {
        registryLock.lock()
        registered.removeAll()
        registryLock.unlock()
        frameLock.lock()
        frameCache.removeAll()
        frameOrder.removeAll()
        frameCacheCost = 0
        clipSizes.removeAll()
        frameLock.unlock()
        // 直接清空整个素材目录（含未注册的残留目录）
        // 等待已经排队的清单写入完成，再清空目录；否则旧的异步写入可能在清空后
        // 重新创建 clip.json，导致“清空后素材又回来”。
        manifestQueue.sync {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }

    public var totalSizeBytes: Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            // .trash 中是等待后台删除的目录，不属于当前素材库占用。
            if url.pathComponents.contains(".trash") { continue }
            if let values = try? url.resourceValues(forKeys: Set(keys)),
               values.isDirectory != true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - 清单

    private func manifestURL(for id: String) -> URL {
        rootURL.appendingPathComponent(id).appendingPathComponent("clip.json")
    }

    private func persistManifest(for clip: SegmentedClip) {
        guard let data = manifestData(for: clip) else { return }
        manifestQueue.sync {
            try? data.write(to: manifestURL(for: clip.id))
        }
    }

    private func manifestData(for clip: SegmentedClip) -> Data? {
        let manifest = ClipManifest(
            id: clip.id,
            name: clip.name,
            fps: clip.fps,
            frameCount: clip.frameCount,
            width: clip.width,
            height: clip.height,
            createdAt: clip.createdAt,
            audioFilename: clip.audioURL?.lastPathComponent,
            edgeStyle: clip.edgeStyle,
            edgeLineStyle: clip.edgeLineStyle,
            edgeThickness: clip.edgeThickness,
            edgeColorHex: clip.edgeColorHex,
            stickerStyle: clip.stickerStyle,
            playbackSpeed: clip.playbackSpeed,
            excludedFrames: Array(clip.excludedFrames).sorted()
        )
        return try? JSONEncoder().encode(manifest)
    }
}

/// 素材元数据清单（磁盘恢复用）
private struct ClipManifest: Codable {
    let id: String
    let name: String
    let fps: Double
    let frameCount: Int
    let width: Int
    let height: Int
    let createdAt: Date
    let audioFilename: String?
    let edgeStyle: ClipEdgeStyle
    let edgeLineStyle: EdgeLineStyle
    let edgeThickness: EdgeThickness
    let edgeColorHex: String
    let stickerStyle: StickerStyle
    let playbackSpeed: Double
    let excludedFrames: [Int]

    private enum CodingKeys: String, CodingKey {
        case id, name, fps, frameCount, width, height, createdAt, audioFilename
        case edgeStyle, edgeLineStyle, edgeThickness, edgeColorHex, stickerStyle
        case playbackSpeed, excludedFrames
    }

    init(
        id: String,
        name: String,
        fps: Double,
        frameCount: Int,
        width: Int,
        height: Int,
        createdAt: Date,
        audioFilename: String?,
        edgeStyle: ClipEdgeStyle,
        edgeLineStyle: EdgeLineStyle,
        edgeThickness: EdgeThickness,
        edgeColorHex: String,
        stickerStyle: StickerStyle,
        playbackSpeed: Double,
        excludedFrames: [Int]
    ) {
        self.id = id
        self.name = name
        self.fps = fps
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.audioFilename = audioFilename
        self.edgeStyle = edgeStyle
        self.edgeLineStyle = edgeLineStyle
        self.edgeThickness = edgeThickness
        self.edgeColorHex = edgeColorHex
        self.stickerStyle = stickerStyle
        self.playbackSpeed = playbackSpeed
        self.excludedFrames = excludedFrames
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        fps = try values.decode(Double.self, forKey: .fps)
        frameCount = try values.decode(Int.self, forKey: .frameCount)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        // 创建时间只影响排序；旧的本地目录没有该字段时仍可恢复素材。
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        audioFilename = try values.decodeIfPresent(String.self, forKey: .audioFilename)

        let encodedEdgeStyle = try values.decodeIfPresent(String.self, forKey: .edgeStyle)
        var recoveredEdgeStyle = ClipEdgeStyle(rawValue: encodedEdgeStyle ?? "") ?? .none
        var recoveredLineStyle = EdgeLineStyle.solid
        var recoveredColor = try values.decodeIfPresent(String.self, forKey: .edgeColorHex) ?? "FFFFFF"

        // 仅用于恢复本机已经存在的旧清单；不会把这些旧值重新写回公共模型。
        switch encodedEdgeStyle {
        case "whiteOutline":
            recoveredEdgeStyle = .outline
            recoveredColor = "FFFFFF"
        case "blackOutline":
            recoveredEdgeStyle = .outline
            recoveredColor = "000000"
        case "goldOutline":
            recoveredEdgeStyle = .outline
            recoveredColor = "E8C05C"
        case "outlineSolid":
            recoveredEdgeStyle = .outline
            recoveredLineStyle = .solid
        case "outlineDashed", "outlineDotted":
            recoveredEdgeStyle = .outline
            recoveredLineStyle = .dashed
        default:
            break
        }
        if let rawLineStyle = try values.decodeIfPresent(String.self, forKey: .edgeLineStyle),
           let lineStyle = EdgeLineStyle(rawValue: rawLineStyle) {
            recoveredLineStyle = lineStyle
        }
        edgeStyle = recoveredEdgeStyle
        edgeLineStyle = recoveredLineStyle
        let rawThickness = try values.decodeIfPresent(String.self, forKey: .edgeThickness) ?? ""
        edgeThickness = EdgeThickness(rawValue: rawThickness) ?? .medium
        edgeColorHex = recoveredColor
        let rawStickerStyle = try values.decodeIfPresent(String.self, forKey: .stickerStyle) ?? ""
        stickerStyle = StickerStyle(rawValue: rawStickerStyle) ?? .none
        playbackSpeed = try values.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1
        excludedFrames = try values.decodeIfPresent([Int].self, forKey: .excludedFrames) ?? []
    }
}

/// 将 CGImage 写入 PNG 文件（跨平台，不依赖 UIKit）
public func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

/// 将 CGImage 编码为 PNG Data
public func pngData(from image: CGImage) -> Data? {
    guard let data = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(
              data, UTType.png.identifier as CFString, 1, nil
          ) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}
