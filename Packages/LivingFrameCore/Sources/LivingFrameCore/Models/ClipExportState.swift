import Foundation

/// GIF 导出期间会被渲染器读取的素材效果快照。
/// 这是值类型，导出开始后不会随 AppState/FrameCache 中的素材设置变化。
public struct ClipGIFEffectSnapshot: Equatable, Sendable {
    private struct Values: Equatable, Sendable {
        let edgeStyle: ClipEdgeStyle
        let edgeLineStyle: EdgeLineStyle
        let edgeThickness: EdgeThickness
        let edgeColorHex: String
        let stickerStyle: StickerStyle
    }

    private let values: Values

    public var edgeStyle: String { values.edgeStyle.rawValue }
    public var edgeLineStyle: String { values.edgeLineStyle.rawValue }
    public var edgeThickness: String { values.edgeThickness.rawValue }
    public var edgeColorHex: String { values.edgeColorHex }
    public var stickerStyle: String { values.stickerStyle.rawValue }

    public init(clip: SegmentedClip) {
        values = Values(
            edgeStyle: clip.edgeStyle,
            edgeLineStyle: clip.edgeLineStyle,
            edgeThickness: clip.edgeThickness,
            edgeColorHex: clip.edgeColorHex.uppercased(),
            stickerStyle: clip.stickerStyle
        )
    }
}

public struct ClipExportState: Equatable {
    private var exportedRotationQuarterTurns: Int?
    private var exportedCropKey: String?
    private var exportedEffects: ClipGIFEffectSnapshot?

    public init() {}

    public mutating func markExported(
        for rotationQuarterTurns: Int,
        cropKey: String,
        resolution: ExportResolution = .p720,
        fps: Double = 15,
        effects: ClipGIFEffectSnapshot? = nil
    ) {
        exportedRotationQuarterTurns = rotationQuarterTurns
        exportedCropKey = cropKey
        exportedResolution = resolution
        exportedFPS = fps
        exportedEffects = effects
    }

    public func isCurrent(
        for rotationQuarterTurns: Int,
        cropKey: String,
        resolution: ExportResolution = .p720,
        fps: Double = 15,
        effects: ClipGIFEffectSnapshot? = nil
    ) -> Bool {
        exportedRotationQuarterTurns == rotationQuarterTurns
            && exportedCropKey == cropKey
            && exportedResolution == resolution
            && exportedFPS == fps
            && exportedEffects == effects
    }

    private var exportedResolution: ExportResolution?
    private var exportedFPS: Double?
}
