import Foundation

/// 时间轴两侧手柄的职责。
///
/// 检查器定义 `SourcePlaybackRange`；时间轴只调整 `TimelinePlaybackState`
/// 的工程播放窗口，不改写源范围。
public enum TimelineTrimHandle: Sendable {
    case leading
    case trailing
}

/// 检查器源范围与时间轴播放窗口的组合状态。
public struct TimelinePlaybackState: Equatable, Sendable {
    public let sourceRange: SourcePlaybackRange
    public let timelineStart: TimeInterval
    public let timelineEnd: TimeInterval
    /// 第一次播放相对 sourceRange.start 的偏移；循环回绕仍从 sourceRange.start 开始。
    public let firstPlaybackOffset: TimeInterval

    public init(
        sourceRange: SourcePlaybackRange,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval,
        firstPlaybackOffset: TimeInterval = 0
    ) {
        self.sourceRange = sourceRange
        self.timelineStart = timelineStart
        self.timelineEnd = max(timelineEnd, timelineStart)
        let offset = firstPlaybackOffset.isFinite ? firstPlaybackOffset : 0
        let wrappedOffset = offset.truncatingRemainder(dividingBy: sourceRange.span)
        self.firstPlaybackOffset = wrappedOffset >= 0
            ? wrappedOffset
            : wrappedOffset + sourceRange.span
    }

    public var timelineDuration: TimeInterval {
        max(timelineEnd - timelineStart, 0)
    }
}

/// 一次时间轴拖拽的纯计算结果，供预览和提交共同使用。
public struct TimelineTrimResult: Equatable, Sendable {
    public let state: TimelinePlaybackState
    public let playbackCount: Int

    public var isLooping: Bool { playbackCount > 1 }

    public init(state: TimelinePlaybackState, playbackCount: Int) {
        self.state = state
        self.playbackCount = max(playbackCount, 1)
    }
}

/// 时间轴播放规则的唯一实现。
public enum TimelinePlaybackRules {
    private static let minimumTimelineDuration: TimeInterval = 0.1
    private static let maximumPlaybackCount = 99

    /// 调整时间轴播放窗口。
    ///
    /// `state.sourceRange` 是检查器设置的一个完整循环单元，拖拽过程中始终
    /// 原样返回。窗口短于一个循环时只播放循环单元的前半段；窗口超过一个
    /// 循环时才增加播放次数。
    public static func trim(
        _ state: TimelinePlaybackState,
        handle: TimelineTrimHandle,
        delta: TimeInterval,
        playbackRate: TimeInterval
    ) -> TimelineTrimResult {
        let rate = max(playbackRate.isFinite ? playbackRate : 1, 0.01)
        let cycleDuration = state.sourceRange.span / rate
        let minimumDuration = min(minimumTimelineDuration, cycleDuration)
        var start = state.timelineStart
        var end = state.timelineEnd

        switch handle {
        case .leading:
            let requestedStart = max(state.timelineStart + delta, 0)
            start = min(requestedStart, state.timelineEnd - minimumDuration)
            let timelineDelta = start - state.timelineStart
            let offset = state.firstPlaybackOffset + timelineDelta * rate
            let nextState = TimelinePlaybackState(
                sourceRange: state.sourceRange,
                timelineStart: start,
                timelineEnd: end,
                firstPlaybackOffset: offset
            )
            return TimelineTrimResult(
                state: nextState,
                playbackCount: playbackCount(
                    for: nextState.timelineDuration,
                    cycleDuration: cycleDuration,
                    firstPlaybackOffset: nextState.firstPlaybackOffset,
                    playbackRate: rate
                )
            )
        case .trailing:
            let requestedEnd = state.timelineEnd + delta
            end = max(state.timelineStart + minimumDuration, requestedEnd)
        }

        let nextState = TimelinePlaybackState(
            sourceRange: state.sourceRange,
            timelineStart: start,
            timelineEnd: end,
            firstPlaybackOffset: state.firstPlaybackOffset
        )
        return TimelineTrimResult(
            state: nextState,
            playbackCount: playbackCount(
                for: nextState.timelineDuration,
                cycleDuration: cycleDuration,
                firstPlaybackOffset: nextState.firstPlaybackOffset,
                playbackRate: rate
            )
        )
    }

    public static func playbackCount(
        for timelineDuration: TimeInterval,
        cycleDuration: TimeInterval,
        firstPlaybackOffset: TimeInterval = 0,
        playbackRate: TimeInterval = 1
    ) -> Int {
        let safeDuration = max(timelineDuration.isFinite ? timelineDuration : 0, 0)
        let safeCycle = max(cycleDuration.isFinite ? cycleDuration : 0.001, 0.001)
        let safeRate = max(playbackRate.isFinite ? playbackRate : 1, 0.01)
        let safeOffset = max(firstPlaybackOffset.isFinite ? firstPlaybackOffset : 0, 0)
        let sourceDistance = safeOffset + safeDuration * safeRate
        let sourceCycle = safeCycle * safeRate
        let count = Int(ceil(sourceDistance / sourceCycle - 0.000001))
        return min(max(count, 1), maximumPlaybackCount)
    }

    /// 返回循环分割线相对有效播放区起点的时间位置。
    ///
    /// 第一次播放可能从循环单元中间开始，所以第一条分割线位于“首轮剩余
    /// 时长”处；之后的分割线才以完整循环时长递增。
    public static func loopBoundaryOffsets(
        firstPlaybackOffset: TimeInterval,
        cycleDuration: TimeInterval,
        playbackCount: Int,
        playbackRate: TimeInterval = 1
    ) -> [TimeInterval] {
        guard playbackCount > 1 else { return [] }
        let safeCycleDuration = max(
            cycleDuration.isFinite ? cycleDuration : 0.001,
            0.001
        )
        let safeRate = max(playbackRate.isFinite ? playbackRate : 1, 0.01)
        let safeOffset = max(firstPlaybackOffset.isFinite ? firstPlaybackOffset : 0, 0)
        let firstPassDuration = max(safeCycleDuration - safeOffset / safeRate, 0)
        return (1..<min(playbackCount, maximumPlaybackCount)).map { cycle in
            firstPassDuration + Double(cycle - 1) * safeCycleDuration
        }
    }

    /// 用离散帧验证播放顺序的测试辅助方法。
    /// `sourceRange` 使用从 1 开始的帧号；`playbackFrameCount` 是时间轴窗口
    /// 包含的帧数，不是循环次数。
    public static func frames(
        from sourceFrames: [Int],
        sourceRange: ClosedRange<Int>,
        playbackFrameCount: Int,
        firstPlaybackOffsetFrame: Int = 0
    ) -> [Int] {
        guard !sourceFrames.isEmpty, playbackFrameCount > 0 else { return [] }
        let lower = max(sourceRange.lowerBound - 1, 0)
        let upper = min(sourceRange.upperBound - 1, sourceFrames.count - 1)
        guard lower <= upper else { return [] }

        let cycle = Array(sourceFrames[lower...upper])
        let offset = min(max(firstPlaybackOffsetFrame, 0), max(cycle.count - 1, 0))
        let firstPassRemaining = cycle.count - offset
        return (0..<playbackFrameCount).map { index in
            if index < firstPassRemaining {
                return cycle[offset + index]
            }
            return cycle[(index - firstPassRemaining) % cycle.count]
        }
    }
}
