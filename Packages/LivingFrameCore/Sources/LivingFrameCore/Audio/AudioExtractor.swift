import AVFoundation
import Foundation

public enum AudioError: Error {
    case noAudioTrack
    case exportFailed(String?)
}

/// 从视频/Live Photo 提取音轨为 m4a
public struct AudioExtractor {
    public init() {}

    /// 有音频轨则导出 m4a 并返回 true；无音频轨返回 false
    public func extractAudio(
        from sourceURL: URL,
        to destinationURL: URL,
        timeRange: CMTimeRange? = nil
    ) async throws -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return false }
        try? FileManager.default.removeItem(at: destinationURL)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.exportFailed(nil)
        }
        session.shouldOptimizeForNetworkUse = false
        if let timeRange {
            session.timeRange = timeRange
        }

        do {
            try await session.export(to: destinationURL, as: .m4a)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AudioError.exportFailed(error.localizedDescription)
        }
        return true
    }
}
