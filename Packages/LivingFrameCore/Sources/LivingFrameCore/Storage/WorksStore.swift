import Foundation

/// 作品持久化：Documents/Works/{id}/（work.json + poster.png）
public struct WorksStore {
    public let rootURL: URL
    private let fileManager: FileManager
    /// 所有作品文件操作共用一个队列，避免保存、重命名、删除任务乱序覆盖。
    private let ioQueue = DispatchQueue(label: "livingframe.works-store", qos: .utility)

    public init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(rootURL: documents.appendingPathComponent("Works", isDirectory: true), fileManager: fileManager)
    }

    /// 指定存储目录，供隔离的存储测试及受控容器使用。
    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func loadWorks() -> [WorkItem] {
        ioQueue.sync {
            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            } catch {
                LogStore.log("works.load directory failed error=\(error)")
                return []
            }

            let works = entries.compactMap { dir -> WorkItem? in
                // 作品目录由 UUID 命名；忽略 .trash 等内部目录。
                guard dir.hasDirectoryPath, UUID(uuidString: dir.lastPathComponent) != nil else { return nil }
                let url = dir.appendingPathComponent("work.json")
                do {
                    let data = try Data(contentsOf: url)
                    return try JSONDecoder().decode(WorkItem.self, from: data)
                } catch {
                    LogStore.log("works.load record failed id=\(dir.lastPathComponent) error=\(error)")
                    return nil
                }
            }
            return works.sorted { $0.lastSavedAt > $1.lastSavedAt }
        }
    }

    @discardableResult
    public func save(_ work: WorkItem) throws -> URL {
        try ioQueue.sync {
            let dir = rootURL.appendingPathComponent(work.id.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(work)
            let jsonURL = dir.appendingPathComponent("work.json")
            // 封面先落盘，work.json 最后作为该版本的提交点；atomic 避免中断时
            // 留下半截 JSON，导致整个作品无法被解码。
            try work.posterData.write(to: dir.appendingPathComponent("poster.png"), options: .atomic)
            try data.write(to: jsonURL, options: .atomic)
            return jsonURL
        }
    }

    public func delete(_ work: WorkItem) {
        ioQueue.sync {
            let sourceURL = rootURL.appendingPathComponent(work.id.uuidString)
            guard fileManager.fileExists(atPath: sourceURL.path) else { return }
            let trashRoot = rootURL.appendingPathComponent(".trash", isDirectory: true)
            try? fileManager.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let trashURL = trashRoot.appendingPathComponent("\(work.id.uuidString)-\(UUID().uuidString)")
            if (try? fileManager.moveItem(at: sourceURL, to: trashURL)) != nil {
                try? fileManager.removeItem(at: trashURL)
            } else {
                try? fileManager.removeItem(at: sourceURL)
            }
        }
    }
}
