import Foundation

/// The available cutout engines.
///
/// `visionPerson` remains in the model so existing saved settings and code
/// paths can be migrated safely, but the app currently hides that entry from
/// the user. The default and only visible route is the original foreground
/// extractor.
public enum SegmentationAlgorithm: String, CaseIterable, Identifiable, Sendable {
    /// Original class-agnostic foreground lifting. It keeps all salient
    /// foreground instances and does not attempt to identify a person.
    case foreground

    /// Existing Apple Vision person-instance path. Kept for compatibility,
    /// but hidden from the current UI until the multi-person flow is ready.
    case visionPerson

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .foreground: return "原始前景提取"
        case .visionPerson: return "Vision 人物实例"
        }
    }

    public var subtitle: String {
        switch self {
        case .foreground: return "不区分人物，提取画面中的全部前景"
        case .visionPerson: return "识别多个人物后选择要保留的主体"
        }
    }

    public var systemImage: String {
        switch self {
        case .foreground: return "wand.and.stars"
        case .visionPerson: return "person.2"
        }
    }
}
