import Foundation
import LivingFrameCore

/// 作品文件的唯一写入入口。actor 保证保存、复制、重命名和删除按调用顺序执行，
/// 避免多个后台任务互相覆盖，也让磁盘操作脱离主线程。
actor WorkPersistenceCoordinator {
    private let store: WorksStore

    init(store: WorksStore) {
        self.store = store
    }

    func saveAndLoad(_ work: WorkItem) -> (Bool, [WorkItem]) {
        do {
            try store.save(work)
            return (true, store.loadWorks())
        } catch {
            LogStore.log("work.save failed: \(error)")
            return (false, [])
        }
    }

    /// 批量写入经过草稿策略整理后的作品，避免清理旧草稿时留下半套状态。
    func saveAndLoad(_ works: [WorkItem]) -> (Bool, [WorkItem]) {
        do {
            for work in works {
                try store.save(work)
            }
            return (true, store.loadWorks())
        } catch {
            LogStore.log("work.batchSave failed: \(error)")
            return (false, [])
        }
    }

    /// 在 actor 内基于磁盘上的最新列表执行“只保留最新一份草稿”策略，
    /// 避免两个自动保存任务各自拿旧内存列表归一化，互相覆盖草稿状态。
    func saveApplyingDraftPolicy(_ work: WorkItem) -> (Bool, [WorkItem]) {
        var candidates = store.loadWorks()
        if let index = candidates.firstIndex(where: { $0.id == work.id }) {
            candidates[index] = work
        } else {
            candidates.insert(work, at: 0)
        }

        let normalized = normalizedVisibleWorks(from: candidates)
        let normalizedIDs = Set(normalized.map(\.id))
        let orphaned = candidates.filter { !normalizedIDs.contains($0.id) }
        let changed = normalized.filter { normalizedWork in
            candidates.first(where: { $0.id == normalizedWork.id }) != normalizedWork
        }
        var toPersist: [WorkItem] = []
        if let current = normalized.first(where: { $0.id == work.id }) {
            // 先提交当前作品，再清理旧草稿；中断时宁可暂时多留一份旧草稿，
            // 也不要先删掉旧稿却还没把用户最新编辑写进去。
            toPersist.append(current)
        }
        toPersist.append(contentsOf: changed.filter { $0.id != work.id })

        do {
            for item in toPersist {
                try store.save(item)
            }
            for item in orphaned {
                store.delete(item)
            }
            return (true, store.loadWorks())
        } catch {
            LogStore.log("work.draftPolicySave failed: \(error)")
            return (false, [])
        }
    }

    /// Normalize legacy draft records at launch and remove draft-only containers
    /// whose draft was already discarded or superseded.
    func loadAndNormalize() -> [WorkItem] {
        let loaded = store.loadWorks()
        let normalized = normalizedVisibleWorks(from: loaded)
        let normalizedIDs = Set(normalized.map(\.id))
        let orphaned = loaded.filter { !normalizedIDs.contains($0.id) }
        let changed = normalized.filter { normalizedWork in
            loaded.first(where: { $0.id == normalizedWork.id }) != normalizedWork
        }

        do {
            for item in changed {
                try store.save(item)
            }
            for item in orphaned {
                store.delete(item)
            }
            return store.loadWorks()
        } catch {
            LogStore.log("work.loadNormalization failed: \(error)")
            return loaded
        }
    }

    func load() -> [WorkItem] {
        store.loadWorks()
    }

    private func normalizedVisibleWorks(from works: [WorkItem]) -> [WorkItem] {
        WorkItem.retainingOnlyLatestDraft(in: works)
            .filter { $0.hasSavedVersion || $0.draft != nil }
    }

    func storageSizeBytes(for workID: UUID) -> Int64 {
        store.storageSizeBytes(for: workID)
    }

    func save(_ work: WorkItem, failureMessage: String) -> Bool {
        do {
            try store.save(work)
            return true
        } catch {
            LogStore.log("\(failureMessage): \(error)")
            return false
        }
    }

    func delete(_ work: WorkItem) {
        store.delete(work)
    }
}
