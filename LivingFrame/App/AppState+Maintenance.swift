import Foundation
import LivingFrameCore
import SwiftUI

extension AppState {
    // MARK: - Widget

    func savePosterForWidget() {
        guard let comp = composition,
              let poster = CompositionRenderer().render(comp, at: 0) else { return }
        FrameStore.savePoster(poster, title: comp.name)
    }

    /// 从作品快照生成 Widget 封面，不改变当前编辑页中的工程。
    func savePosterForWidget(_ work: WorkItem) {
        guard let poster = UIImage(data: work.posterData)?.cgImage else { return }
        FrameStore.savePoster(poster, title: work.name)
    }

    // MARK: - 缓存

    /// 清理临时文件：素材（含文件夹内外的所有抠图结果）一律保留，只删导入/导出产生的临时文件。
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
        cacheSizeText = "计算中…"
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
