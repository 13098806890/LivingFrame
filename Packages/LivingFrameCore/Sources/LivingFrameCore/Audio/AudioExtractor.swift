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
    public func extractAudio(from sourceURL: URL, to destinationURL: URL) async throws -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return false }
        try? FileManager.default.removeItem(at: destinationURL)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.exportFailed(nil)
        }
        session.outputURL = destinationURL
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: AudioError.exportFailed(session.error?.localizedDescription))
                }
            }
        }
        return true
    }
}
