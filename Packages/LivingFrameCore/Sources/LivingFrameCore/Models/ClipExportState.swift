import Foundation

public struct ClipExportState: Equatable {
    private var exportedRotationQuarterTurns: Int?
    private var exportedCropKey: String?

    public init() {}

    public mutating func markExported(
        for rotationQuarterTurns: Int,
        cropKey: String,
        resolution: ExportResolution = .p720,
        fps: Double = 15
    ) {
        exportedRotationQuarterTurns = rotationQuarterTurns
        exportedCropKey = cropKey
        exportedResolution = resolution
        exportedFPS = fps
    }

    public func isCurrent(
        for rotationQuarterTurns: Int,
        cropKey: String,
        resolution: ExportResolution = .p720,
        fps: Double = 15
    ) -> Bool {
        exportedRotationQuarterTurns == rotationQuarterTurns
            && exportedCropKey == cropKey
            && exportedResolution == resolution
            && exportedFPS == fps
    }

    private var exportedResolution: ExportResolution?
    private var exportedFPS: Double?
}
