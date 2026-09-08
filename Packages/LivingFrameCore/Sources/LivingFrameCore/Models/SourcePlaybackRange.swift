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
        looping: Bool
    ) -> TimeInterval {
        let elapsed = max(localTime.isFinite ? localTime : 0, 0) * max(playbackRate, 0.01)
        let offset = looping
            ? elapsed.truncatingRemainder(dividingBy: span)
            : min(elapsed, span)
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
