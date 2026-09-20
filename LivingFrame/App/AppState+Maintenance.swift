import Foundation
import LivingFrameCore
import SwiftUI

extension AppState {
    // MARK: - 缓存

    /// 应用启动时清理上次运行遗留的临时文件。当前会话新生成的文件至少保留一天，
    /// 避免影响正在进行的导入、导出或分享操作。
    func cleanupStaleTemporaryFiles(maxAge: TimeInterval = 24 * 60 * 60) {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-max(maxAge, 0))
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            guard let items = try? fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            for item in items where item.lastPathComponent.hasPrefix("LF-") {
                guard let values = try? item.resourceValues(forKeys: keys),
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff else {
                    continue
                }
                try? fileManager.removeItem(at: item)
            }
        }
    }

    /// 清理临时文件：素材（含文件夹内外的所有剪影结果）一律保留，只删导入/导出产生的临时文件。
    func clearCache() {
        let tmp = FileManager.default.temporaryDirectory
        Task.detached(priority: .utility) {
            if let items = try? FileManager.default.contentsOfDirectory(
                at: tmp, includingPropertiesForKeys: nil
            ) {
                for item in items where item.lastPathComponent.hasPrefix("LF-") {
                    try? FileManager.default.removeItem(at: item)
                }
            }
            LogStore.log("clearCache: 已清理临时文件，素材全部保留")
        }
    }

    /// 异步刷新素材占用，避免设置页 body 计算属性反复遍历素材目录。
    func refreshCacheSize() {
        cacheSizeTask?.cancel()
        cacheSizeText = NSLocalizedString("计算中…", comment: "Cache size loading state")
        cacheSizeTask = Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                FrameCache.shared.totalSizeBytes
            }.value
            guard !Task.isCancelled else { return }
            self?.cacheSizeText = ByteCountFormatter.string(
                fromByteCount: bytes,
                countStyle: .file
            )
        }
    }
}
