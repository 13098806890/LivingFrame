import AVFoundation
import Foundation

/// 离线混音（导出用）：AVMutableComposition + AVAudioMix 精确对齐
public struct OfflineAudioMixer {
    public init() {}

    /// 将 audioClips 按时间轴混音为 m4a
    public func mix(
        _ clips: [AudioClip],
        duration: TimeInterval,
        sourceResolver: (String) -> URL?,
        to destinationURL: URL
    ) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioError.exportFailed(NSLocalizedString("无法创建音轨", comment: "Audio export error"))
        }

        for clip in clips {
            guard let url = sourceResolver(clip.sourceID) else { continue }
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let timeRange = CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            do {
                try track.insertTimeRange(
                    timeRange, of: assetTrack,
                    at: CMTime(seconds: clip.startTime, preferredTimescale: 600)
                )
            } catch {
                continue
            }
        }

        // 音量包络（淡入淡出）
        let parameters = AVMutableAudioMixInputParameters(track: track)
        for clip in clips {
            if clip.fadeIn > 0 {
                parameters.setVolumeRamp(
                    fromStartVolume: 0, toEndVolume: clip.volume,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: clip.startTime, preferredTimescale: 600),
                        duration: CMTime(seconds: clip.fadeIn, preferredTimescale: 600)
                    )
                )
            }
            if clip.fadeOut > 0 {
                parameters.setVolumeRamp(
                    fromStartVolume: clip.volume, toEndVolume: 0,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: clip.startTime + clip.duration - clip.fadeOut, preferredTimescale: 600),
                        duration: CMTime(seconds: clip.fadeOut, preferredTimescale: 600)
                    )
                )
            }
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]

        try? FileManager.default.removeItem(at: destinationURL)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.exportFailed(NSLocalizedString("无法创建导出会话", comment: "Audio export error"))
        }
        session.audioMix = audioMix
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
    }
}
