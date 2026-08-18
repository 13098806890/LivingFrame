import AVFoundation
import Foundation

/// 实时音轨播放（编辑预览用）：AVAudioEngine + PlayerNode 调度
/// 与视频预览时钟对齐（误差 <200ms，MVP 可接受）
public final class AudioPreviewEngine {
    private let engine = AVAudioEngine()
    private var nodes: [UUID: AVAudioPlayerNode] = [:]
    private var files: [String: AVAudioFile] = [:]
    private var clips: [AudioClip] = []
    private var sourceResolver: (String) -> URL? = { _ in nil }

    public init() {}

    public func configure(clips: [AudioClip], sourceResolver: @escaping (String) -> URL?) {
        stop()
        self.clips = clips
        self.sourceResolver = sourceResolver
        for clip in clips where files[clip.sourceID] == nil {
            guard let url = sourceResolver(clip.sourceID) else { continue }
            files[clip.sourceID] = try? AVAudioFile(forReading: url)
        }
    }

    /// 从 startTime（秒）开始播放全部音轨
    public func play(from startTime: TimeInterval) {
        stop()
        guard !clips.isEmpty else { return }
        do {
            try engine.start()
        } catch {
            return
        }
        for clip in clips {
            guard let file = files[clip.sourceID] else { continue }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            node.volume = clip.volume
            nodes[clip.id] = node

            let sampleRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(max(0, startTime - clip.startTime) * sampleRate)
            let availableFrames = max(0, file.length - startFrame)
            let clipFrames = Int64(clip.duration * sampleRate)
            let frameCount = AVAudioFrameCount(min(availableFrames, clipFrames))
            guard frameCount > 0 else {
                node.stop()
                engine.detach(node)
                nodes[clip.id] = nil
                continue
            }
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
            node.play()
        }
    }

    /// 播放中实时调整某条音轨音量：不重建引擎（重建会打断播放），
    /// 同时更新内部 clips 快照，保证下次 play() 使用最新音量
    public func updateVolume(_ volume: Float, for clipID: UUID) {
        nodes[clipID]?.volume = volume
        if let index = clips.firstIndex(where: { $0.id == clipID }) {
            var updated = clips[index]
            updated.volume = volume
            clips[index] = updated
        }
    }

    public func stop() {
        for node in nodes.values {
            node.stop()
            engine.detach(node)
        }
        nodes.removeAll()
        engine.stop()
    }

    public var isRunning: Bool { engine.isRunning }
}
