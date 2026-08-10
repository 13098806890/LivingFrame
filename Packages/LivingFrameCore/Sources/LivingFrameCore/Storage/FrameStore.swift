import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// App Group 共享容器：Widget 静态帧读写
public struct FrameStore {
    public static let appGroupID = "group.com.livingframe.shared"
    private static let posterFileName = "poster.png"
    private static let titleKey = "posterTitle"

    public static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static func savePoster(_ image: CGImage, title: String) {
        guard let url = containerURL() else { return }
        let fileURL = url.appendingPathComponent(posterFileName)
        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            UserDefaults(suiteName: appGroupID)?.set(title, forKey: titleKey)
        }
    }

    public static func loadPoster() -> CGImage? {
        guard let url = containerURL() else { return nil }
        let fileURL = url.appendingPathComponent(posterFileName)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func loadTitle() -> String? {
        UserDefaults(suiteName: appGroupID)?.string(forKey: titleKey)
    }
}
