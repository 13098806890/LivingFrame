import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 磁盘素材库：管理抠图素材的 PNG 序列目录（Documents/Library/Clips，持久保存）
public final class FrameCache {
    public static let shared = FrameCache()

    private let rootURL: URL
    private var registered: [String: SegmentedClip] = [:]
    /// 预览帧解码缓存（避免每帧重复磁盘解码导致素材库卡顿）
    private let frameLock = NSLock()
    private var frameCache: [String: CGImage] = [:]
    /// 多个素材循环播放时缓存须覆盖各素材最近几帧，太小会导致频繁清空重解码
    private let frameCacheMax = 128
    /// 素材占用空间缓存（clipID → bytes）
    private var clipSizes: [String: Int64] = [:]

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
        registered[clip.id] = clip
        saveManifest(for: clip)
    }

    public func clip(id: String) -> SegmentedClip? {
        registered[id]
    }

    /// 带缓存的帧解码（预览/渲染共用，超出容量整体清空）
    public func cachedFrame(for clip: SegmentedClip, index: Int) -> CGImage? {
        let key = "\(clip.id):\(index)"
        frameLock.lock()
        defer { frameLock.unlock() }
        if let image = frameCache[key] { return image }
        guard let image = clip.loadFrame(index: index) else { return nil }
        frameCache[key] = image
        if frameCache.count > frameCacheMax {
            frameCache.removeAll()
        }
        return image
    }

    /// 低分辨率缩略帧解码（素材库/选择器预览用，直接按目标尺寸解码，省去全尺寸解码）
    public func cachedThumbnail(for clip: SegmentedClip, index: Int, maxPixelSize: CGFloat) -> CGImage? {
        let key = "\(clip.id):\(index):thumb\(Int(maxPixelSize))"
        frameLock.lock()
        defer { frameLock.unlock() }
        if let image = frameCache[key] { return image }
        let url = clip.frameURL(index: index) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        frameCache[key] = image
        if frameCache.count > frameCacheMax {
            frameCache.removeAll()
        }
        return image
    }

    /// 重新扫描磁盘，恢复所有素材注册（启动时调用）
    public func reload() {
        registered.removeAll()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        ) else { return }
        for dir in entries where dir.hasDirectoryPath {
            let id = dir.lastPathComponent
            guard let data = try? Data(contentsOf: manifestURL(for: id)),
                  let manifest = try? JSONDecoder().decode(ClipManifest.self, from: data) else { continue }
            let audioURL = manifest.audioFilename.map { dir.appendingPathComponent($0) }
            registered[id] = SegmentedClip(
                id: manifest.id,
                name: manifest.name,
                fps: manifest.fps,
                frameCount: manifest.frameCount,
                width: manifest.width,
                height: manifest.height,
                folderURL: dir,
                audioURL: audioURL,
                edgeStyle: manifest.edgeStyle ?? .none,
                edgeLineStyle: manifest.edgeLineStyle ?? .solid,
                edgeThickness: manifest.edgeThickness ?? .medium,
                edgeColorHex: manifest.edgeColorHex ?? "FFFFFF",
                stickerStyle: manifest.stickerStyle ?? .none
            )
        }
    }

    public func allClips() -> [SegmentedClip] {
        registered.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func removeClip(id: String) {
        registered[id] = nil
        clipSizes[id] = nil
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(id))
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
        registered.removeAll()
        // 直接清空整个素材目录（含未注册的残留目录）
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public var totalSizeBytes: Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
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

    private func saveManifest(for clip: SegmentedClip) {
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
            stickerStyle: clip.stickerStyle
        )
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL(for: clip.id))
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
    let edgeStyle: ClipEdgeStyle?
    let edgeLineStyle: EdgeLineStyle?
    let edgeThickness: EdgeThickness?
    let edgeColorHex: String?
    let stickerStyle: StickerStyle?
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
