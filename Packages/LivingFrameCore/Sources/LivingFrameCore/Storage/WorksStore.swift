import Foundation

/// 作品持久化：Documents/Works/{id}/（work.json + poster.png）
public struct WorksStore {
    public let rootURL: URL
    /// 所有作品文件操作共用一个队列，避免保存、重命名、删除任务乱序覆盖。
    private let ioQueue = DispatchQueue(label: "livingframe.works-store", qos: .utility)

    public init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = documents.appendingPathComponent("Works", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func loadWorks() -> [WorkItem] {
        ioQueue.sync {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil
            ) else { return [] }
            return entries
                .filter { $0.hasDirectoryPath }
                .compactMap { dir in
                    let url = dir.appendingPathComponent("work.json")
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(WorkItem.self, from: data)
                }
                .sorted { $0.lastSavedAt > $1.lastSavedAt }
        }
    }

    @discardableResult
    public func save(_ work: WorkItem) throws -> URL {
        try ioQueue.sync {
            let dir = rootURL.appendingPathComponent(work.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(work)
            let jsonURL = dir.appendingPathComponent("work.json")
            try data.write(to: jsonURL)
            try work.posterData.write(to: dir.appendingPathComponent("poster.png"))
            return jsonURL
        }
    }

    public func delete(_ work: WorkItem) {
        ioQueue.sync {
            let fileManager = FileManager.default
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
