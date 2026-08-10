import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 磁盘帧缓存：管理抠图素材的 PNG 序列目录
public final class FrameCache {
    public static let shared = FrameCache()

    private let rootURL: URL
    private var registered: [String: SegmentedClip] = [:]

    private init() {
        rootURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SegmentedClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func makeClipFolder(id: String) throws -> URL {
        let url = rootURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func register(_ clip: SegmentedClip) {
        registered[clip.id] = clip
    }

    public func clip(id: String) -> SegmentedClip? {
        registered[id]
    }

    public func removeClip(id: String) {
        registered[id] = nil
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(id))
    }

    public func removeAll() {
        registered.removeAll()
        // 直接清空整个缓存目录（含未注册的残留目录）
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
