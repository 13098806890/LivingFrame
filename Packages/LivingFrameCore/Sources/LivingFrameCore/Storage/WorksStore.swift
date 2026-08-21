import Foundation

/// 作品持久化：Documents/Works/{id}/（work.json + poster.png）
public struct WorksStore {
    public let rootURL: URL

    public init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = documents.appendingPathComponent("Works", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func loadWorks() -> [WorkItem] {
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

    @discardableResult
    public func save(_ work: WorkItem) throws -> URL {
        let dir = rootURL.appendingPathComponent(work.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(work)
        let jsonURL = dir.appendingPathComponent("work.json")
        try data.write(to: jsonURL)
        try work.posterData.write(to: dir.appendingPathComponent("poster.png"))
        return jsonURL
    }

    public func delete(_ work: WorkItem) {
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(work.id.uuidString))
    }
}
