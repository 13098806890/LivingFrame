import Foundation

/// 素材文件夹：树形结构（parentID 为 nil 表示根层级），按名称组织已抠图素材
public struct LibraryFolder: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var createdAt: Date
    /// 父文件夹 ID（nil = 根层级）
    public var parentID: String?
    public var clipIDs: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        clipIDs: [String] = [],
        parentID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.clipIDs = clipIDs
        self.parentID = parentID
    }
}
