import Foundation

/// 素材文件夹持久化：Documents/Library/folders.json
public struct LibraryFolderStore {
    public let rootURL: URL
    public let foldersURL: URL

    public init(fileManager: FileManager = .default) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = documents.appendingPathComponent("Library", isDirectory: true)
        foldersURL = rootURL.appendingPathComponent("folders.json")
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func load() -> [LibraryFolder] {
        guard let data = try? Data(contentsOf: foldersURL) else { return [] }
        return (try? JSONDecoder().decode([LibraryFolder].self, from: data)) ?? []
    }

    public func save(_ folders: [LibraryFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: foldersURL, options: .atomic)
    }
}
