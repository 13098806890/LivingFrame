import Foundation

/// A user-selectable GIF output combination and its estimated file size.
public struct GIFExportPreset: Identifiable, Equatable, Sendable {
    public let resolution: ExportResolution
    public let fps: Double
    public var estimatedBytes: Int64

    public var id: String { "\(resolution.rawValue)-\(fps)" }

    public init(resolution: ExportResolution, fps: Double, estimatedBytes: Int64 = 0) {
        self.resolution = resolution
        self.fps = fps
        self.estimatedBytes = estimatedBytes
    }

    public static func resolutionOptions(maxSourceDimension: CGFloat) -> [ExportResolution] {
        ExportResolution.gifOptions(maxSourceDimension: maxSourceDimension)
    }

    public static func fpsOptions(maxSourceFPS: Double) -> [Double] {
        ExportFPSPolicy.availableOptions(maxSourceFPS: maxSourceFPS)
    }

    /// Chooses the largest estimated output that remains under the limit.
    /// If every option exceeds the limit, chooses the smallest estimate.
    public static func defaultPreset(
        from presets: [GIFExportPreset],
        limitBytes: Int64 = 10 * 1024 * 1024
    ) -> GIFExportPreset? {
        let valid = presets.filter { $0.estimatedBytes > 0 && $0.estimatedBytes < .max }
        guard !valid.isEmpty else { return nil }
        let underLimit = valid.filter { $0.estimatedBytes <= limitBytes }
        return (underLimit.isEmpty ? valid : underLimit).max {
            if $0.estimatedBytes != $1.estimatedBytes {
                return $0.estimatedBytes < $1.estimatedBytes
            }
            let leftSize = Double($0.resolution.maxPixelSize ?? .greatestFiniteMagnitude)
            let rightSize = Double($1.resolution.maxPixelSize ?? .greatestFiniteMagnitude)
            return leftSize * $0.fps < rightSize * $1.fps
        }
    }
}
