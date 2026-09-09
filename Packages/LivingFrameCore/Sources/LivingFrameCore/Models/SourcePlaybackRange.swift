import Foundation

/// 一段可播放的源素材范围。
///
/// `start`/`end` 表示源素材内部的入点和出点，`duration` 表示完整源素材时长。
/// 视频、动态贴纸和动态背景都通过这个类型进行边界归一化与循环播放计算。
public struct SourcePlaybackRange: Equatable, Sendable {
    public let duration: TimeInterval
    public let start: TimeInterval
    public let end: TimeInterval

    public init(
        duration: TimeInterval,
        start: TimeInterval = 0,
        end: TimeInterval = .greatestFiniteMagnitude
    ) {
        let safeDuration = duration.isFinite && duration > 0.001 ? duration : 0.001
        let safeStart = min(max(start.isFinite ? start : 0, 0), safeDuration)
        let safeEnd = end.isFinite && end < .greatestFiniteMagnitude / 2
            ? min(max(end, safeStart), safeDuration)
            : safeDuration
        self.duration = safeDuration
        self.start = safeStart
        self.end = safeEnd
    }

    public var span: TimeInterval {
        max(end - start, 0.001)
    }

    /// 将元素内的播放时间映射为源素材时间。
    /// `localTime` 使用工程时间线秒数，`playbackRate` 使用源素材时间/工程时间。
    public func sourceTime(
        at localTime: TimeInterval,
        playbackRate: TimeInterval = 1,
        phase: TimeInterval = 0,
        looping: Bool
    ) -> TimeInterval {
        let elapsed = max(localTime.isFinite ? localTime : 0, 0) * max(playbackRate, 0.01)
        let safePhase = phase.isFinite ? phase : 0
        let offset: TimeInterval
        if looping {
            // phase 只作用于第一次播放；回绕后必须从 sourceRange.start 开始，
            // 这样左侧时间轴裁剪不会改变检查器定义的循环单元。
            let firstPassRemaining = max(span - min(max(safePhase, 0), span), 0)
            if elapsed < firstPassRemaining {
                offset = min(max(safePhase, 0) + elapsed, span)
            } else {
                let loopElapsed = elapsed - firstPassRemaining
                let wrapped = loopElapsed.truncatingRemainder(dividingBy: span)
                offset = wrapped >= 0 ? wrapped : wrapped + span
            }
        } else {
            offset = min(max(safePhase, 0) + elapsed, span)
        }
        return min(max(start + offset, 0), duration)
    }
}

public extension SegmentedClip {
    /// 所有预览、时间轴和导出路径共用的安全源时长。
    var playbackSourceDuration: TimeInterval {
        let active = activeDuration
        if active.isFinite, active > 0.001 { return active }
        let full = duration
        return full.isFinite && full > 0.001 ? full : 0.001
    }
}

/// 有限动态源的共同时间信息。静态元素没有此信息，只编辑显示时长。
public struct ElementPlaybackSource: Equatable, Sendable {
    public let duration: TimeInterval
    public let playbackRate: Double

    public init(duration: TimeInterval, playbackRate: Double = 1) {
        self.duration = duration.isFinite ? max(duration, 0.001) : 0.001
        self.playbackRate = playbackRate.isFinite ? max(playbackRate, 0.01) : 1
    }

    public func range(for element: CompositionElement) -> SourcePlaybackRange {
        SourcePlaybackRange(duration: duration, start: element.sourceStartTime, end: element.sourceEndTime)
    }

    public func cycleDuration(for element: CompositionElement) -> TimeInterval {
        range(for: element).span / playbackRate
    }
}

public extension CompositionElement {
    func shouldLoop(cycleDuration: TimeInterval) -> Bool {
        if let playbackCount { return playbackCount > 1 }
        // 旧工程仍按原来的时长播放，不在打开工程时擅自缩短。
        return endTime - startTime > cycleDuration + 0.001
    }

    func resolvedPlaybackCount(cycleDuration: TimeInterval) -> Int {
        if let playbackCount { return max(playbackCount, 1) }
        guard shouldLoop(cycleDuration: cycleDuration) else { return 1 }
        let ratio = (endTime - startTime) / max(cycleDuration, 0.001)
        guard ratio.isFinite else { return 1 }
        return Int(min(max(ceil(ratio - 0.000001), 1), 10_000))
    }
}
