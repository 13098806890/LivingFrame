import Foundation

/// User-provided prompt for the SAM2 route.
///
/// The current bundled Apple Prompt Encoder is exported with a single point
/// slot. The runtime evaluates foreground points one at a time and unions
/// their masks, then evaluates background points as subtractive corrections.
/// Keeping the prompt structured lets us swap in a multi-point/box export
/// later without changing the UI or app-level API.
public struct SAM2Prompt: Equatable, Sendable {
    public var foregroundPoints: [CGPoint]
    public var backgroundPoints: [CGPoint]
    public var box: CGRect?

    public init(
        foregroundPoints: [CGPoint] = [],
        backgroundPoints: [CGPoint] = [],
        box: CGRect? = nil
    ) {
        self.foregroundPoints = foregroundPoints
        self.backgroundPoints = backgroundPoints
        self.box = box
    }

    public var primaryForegroundPoint: CGPoint? {
        if let first = foregroundPoints.first {
            return first
        }
        guard let box, box.width > 0, box.height > 0 else { return nil }
        return CGPoint(x: box.midX, y: box.midY)
    }

    public var isUsable: Bool {
        primaryForegroundPoint != nil
    }
}

/// The three supported cutout entry points.
///
/// Keep these cases explicit: each algorithm has a different prompt/selection
/// flow in the app and should not silently fall back to another model.
public enum SegmentationAlgorithm: String, CaseIterable, Identifiable, Sendable {
    /// Original class-agnostic foreground lifting. It keeps all salient
    /// foreground instances and does not attempt to identify a person.
    case foreground

    /// Existing Apple Vision person-instance path. It analyzes tracks first,
    /// then lets the user keep one or more detected people.
    case visionPerson

    /// Hybrid path: SAM2 identifies the object under the user's point, while
    /// Vision renders the complete person instance for cleaner clothing and
    /// body edges. SAM2 remains the fallback for non-person targets.
    case sam2

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .foreground: return "原始前景提取"
        case .visionPerson: return "Vision 人物实例"
        case .sam2: return "SAM2 + Vision 混合人物"
        }
    }

    public var subtitle: String {
        switch self {
        case .foreground: return "不区分人物，提取画面中的全部前景"
        case .visionPerson: return "识别多个人物后选择要保留的主体"
        case .sam2: return "SAM2 认人，Vision 保留完整人物轮廓"
        }
    }

    public var systemImage: String {
        switch self {
        case .foreground: return "wand.and.stars"
        case .visionPerson: return "person.2"
        case .sam2: return "scope"
        }
    }
}
