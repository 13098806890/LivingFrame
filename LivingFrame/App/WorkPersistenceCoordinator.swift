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

    func load() -> [WorkItem] {
        store.loadWorks()
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
