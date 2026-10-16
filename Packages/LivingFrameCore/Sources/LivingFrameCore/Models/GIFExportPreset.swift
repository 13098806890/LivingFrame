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
        ExportFPSPolicy.availableOptions(maxSourceFPS: maxSourceFPS, presets: [15, 30])
    }

    /// Preserve pixel detail when an effect makes GIF frames more expensive.
    /// Prefer the largest resolution, then the fastest frame rate at that
    /// resolution that fits the limit. If none fits, keep the resolution and
    /// choose its smallest estimate; the UI shows that estimate to the user.
    public static func defaultPreset(
        from presets: [GIFExportPreset],
        limitBytes: Int64 = 10 * 1024 * 1024
    ) -> GIFExportPreset? {
        let valid = presets.filter { $0.estimatedBytes > 0 && $0.estimatedBytes < .max }
        guard !valid.isEmpty else { return nil }
        guard let largestPixelSize = valid.map({ $0.resolution.maxPixelSize ?? .greatestFiniteMagnitude }).max() else {
            return nil
        }
        let largestResolution = valid.filter {
            ($0.resolution.maxPixelSize ?? .greatestFiniteMagnitude) == largestPixelSize
        }
        let underLimit = largestResolution.filter { $0.estimatedBytes <= limitBytes }
        if !underLimit.isEmpty {
            return underLimit.max { $0.fps < $1.fps }
        }
        return largestResolution.min { $0.estimatedBytes < $1.estimatedBytes }
    }
}
