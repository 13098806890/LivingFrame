import CoreText
import Foundation

/// 注册随 App 打包的开源字体。
/// 使用运行时注册而不是依赖 Info.plist，避免生成式 Info.plist 丢失 UIAppFonts 配置。
enum BundledFontManager {
    private static let bundledFonts = [
        (name: "NotoSansSC-Variable", postScriptName: "NotoSansSC-Regular"),
        (name: "Inter-Variable", postScriptName: "Inter-Regular")
    ]

    static func registerFonts() {
        for font in bundledFonts {
            guard let url = url(for: font.name) else {
                #if DEBUG
                print("[LivingFrame] bundled font not found: \(font.name).ttf")
                #endif
                continue
            }

            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            #if DEBUG
            if !registered, let error {
                print("[LivingFrame] bundled font registration skipped: \(font.postScriptName), \(error.takeUnretainedValue())")
            }
            #endif
        }
    }

    private static func url(for resourceName: String) -> URL? {
        let fileName = resourceName + ".ttf"
        let candidates = [
            Bundle.main.url(forResource: resourceName, withExtension: "ttf", subdirectory: "Fonts"),
            Bundle.main.url(forResource: resourceName, withExtension: "ttf", subdirectory: "Resources/Fonts"),
            Bundle.main.url(forResource: resourceName, withExtension: "ttf")
        ]

        if let url = candidates.compactMap({ $0 }).first {
            return url
        }

        // 文件系统同步目录在不同 Xcode 版本中可能保留 Resources 这一层，
        // 因此再用实际路径兜底，避免字体已经打包却无法注册。
        return ["Fonts", "Resources/Fonts", ""].compactMap { subdirectory in
            let base = Bundle.main.resourceURL?.appendingPathComponent(subdirectory)
            let url = base?.appendingPathComponent(fileName)
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }.first
    }
}
