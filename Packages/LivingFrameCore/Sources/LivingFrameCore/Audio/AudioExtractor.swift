import AVFoundation
import Foundation

public enum AudioError: Error {
    case noAudioTrack
    case exportFailed(String?)
}

/// AVAssetExportSession 的回调在系统队列执行；这里集中声明它由系统自身负责线程安全，
/// 避免把 NS_SWIFT_NONSENDABLE 类型直接捕获进 @Sendable 回调。
private final class ExportSessionBox: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
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
        session.outputURL = destinationURL
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false
        if let timeRange {
            session.timeRange = timeRange
        }

        let sessionBox = ExportSessionBox(session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionBox.value.exportAsynchronously {
                continuation.resume()
            }
        }
        switch sessionBox.value.status {
        case .completed:
            break
        case .cancelled:
            throw CancellationError()
        default:
            throw AudioError.exportFailed(sessionBox.value.error?.localizedDescription)
        }
        return true
    }
}
