import Foundation

/// Coordinates cache pressure around full-resolution export. Only decoded,
/// reproducible data is released; projects and imported source files are kept.
public enum RenderMemoryController {
    public static func prepareForExport() {
        clearRecreatableCaches()
        LogStore.log("export.cache prepare cleared decoded preview/render caches")
    }

    public static func finishExport() {
        clearRecreatableCaches()
        LogStore.log("export.cache finish cleared decoded export caches")
    }

    private static func clearRecreatableCaches() {
        FrameCache.shared.purgeDecodedFrames()
        BackgroundStore.shared.purgeDecodedMedia()
        BackgroundMaskRenderer.clearCaches()
        PaperEffectRenderer.clearCaches()
        NativePaperEffectRenderer.clearCaches()
        DecorationRenderer.clearSharedCaches()
        CompositionRenderer.clearSharedCaches()
    }
}
