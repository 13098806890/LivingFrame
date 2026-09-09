import XCTest
@testable import LivingFrameCore

final class TimelinePlaybackRulesTests: XCTestCase {
    private let sourceFrames = [1, 2, 3, 4, 5, 6]

    func testExportFPSOptionsAreCappedByMaximumSourceFPS() {
        XCTAssertEqual(ExportFPSPolicy.availableOptions(maxSourceFPS: 30), [10, 15, 30])
        XCTAssertEqual(ExportFPSPolicy.availableOptions(maxSourceFPS: 60), [10, 15, 30, 60])
        XCTAssertEqual(ExportFPSPolicy.availableOptions(maxSourceFPS: 24), [10, 15, 24])
    }

    func testRotationSnapsToNearbyThirtyDegreeMultiples() {
        XCTAssertEqual(
            RotationSnapPolicy.snapped(28 * .pi / 180),
            30 * .pi / 180,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RotationSnapPolicy.snapped(-31 * .pi / 180),
            -30 * .pi / 180,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RotationSnapPolicy.snapped(58 * .pi / 180),
            60 * .pi / 180,
            accuracy: 0.0001
        )
    }

    func testRotationOutsideMagneticRangeRemainsContinuous() {
        XCTAssertEqual(
            RotationSnapPolicy.snapped(36 * .pi / 180),
            36 * .pi / 180,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RotationSnapPolicy.snapped(34 * .pi / 180),
            34 * .pi / 180,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RotationSnapPolicy.snapped(12 * .pi / 180),
            12 * .pi / 180,
            accuracy: 0.0001
        )
    }

    func testShorteningFullSourceThenExtendingRestoresBeforeLooping() {
        let initial = state(sourceRange: 1...5, timelineDuration: 5)

        let shortened = trim(initial, handle: .trailing, delta: -1)
        XCTAssertEqual(shortened.state.sourceRange.start, 0)
        XCTAssertEqual(shortened.state.sourceRange.end, 5)
        XCTAssertEqual(shortened.state.timelineDuration, 4, accuracy: 0.0001)
        XCTAssertEqual(shortened.playbackCount, 1)
        XCTAssertEqual(frames(for: shortened), [1, 2, 3, 4])

        let restored = trim(shortened.state, handle: .trailing, delta: 1)
        XCTAssertEqual(restored.state.timelineDuration, 5, accuracy: 0.0001)
        XCTAssertEqual(restored.playbackCount, 1)
        XCTAssertEqual(frames(for: restored), [1, 2, 3, 4, 5])

        let extended = trim(restored.state, handle: .trailing, delta: 1)
        XCTAssertEqual(extended.state.timelineDuration, 6, accuracy: 0.0001)
        XCTAssertEqual(extended.playbackCount, 2)
        XCTAssertEqual(frames(for: extended), [1, 2, 3, 4, 5, 1])
    }

    func testInspectorRangeDefinesLoopUnitWhenTrailingBarExtends() {
        let initial = state(sourceRange: 1...4, timelineDuration: 4)

        let extended = trim(initial, handle: .trailing, delta: 1)

        XCTAssertEqual(extended.state.sourceRange.start, 0)
        XCTAssertEqual(extended.state.sourceRange.end, 4)
        XCTAssertEqual(extended.playbackCount, 2)
        XCTAssertEqual(frames(for: extended), [1, 2, 3, 4, 1])
    }

    func testLeadingAndTrailingHandlesShortenSymmetricallyWithoutChangingSourceRange() {
        let initial = state(sourceRange: 1...5, timelineDuration: 5)

        let leading = trim(initial, handle: .leading, delta: 1)
        let trailing = trim(initial, handle: .trailing, delta: -1)

        XCTAssertEqual(leading.state.timelineDuration, 4, accuracy: 0.0001)
        XCTAssertEqual(trailing.state.timelineDuration, 4, accuracy: 0.0001)
        XCTAssertEqual(leading.state.sourceRange, trailing.state.sourceRange)
        XCTAssertEqual(leading.state.firstPlaybackOffset, 1, accuracy: 0.0001)
        XCTAssertEqual(frames(for: leading), [2, 3, 4, 5])
        XCTAssertEqual(frames(for: trailing), [1, 2, 3, 4])
    }

    func testLeadingTrimKeepsFirstSourceFrameInactiveAndTrailingExtensionAddsItToLoop() {
        let initial = state(sourceRange: 1...6, timelineDuration: 6)

        let leading = trim(initial, handle: .leading, delta: 1)
        XCTAssertEqual(leading.state.timelineStart, 1, accuracy: 0.0001)
        XCTAssertEqual(leading.state.timelineDuration, 5, accuracy: 0.0001)
        XCTAssertEqual(leading.state.firstPlaybackOffset, 1, accuracy: 0.0001)
        XCTAssertEqual(leading.playbackCount, 1)
        XCTAssertEqual(frames(for: leading), [2, 3, 4, 5, 6])

        let restored = trim(leading.state, handle: .trailing, delta: 1)
        XCTAssertEqual(restored.state.firstPlaybackOffset, 1, accuracy: 0.0001)
        XCTAssertEqual(restored.playbackCount, 2)
        XCTAssertEqual(frames(for: restored), [2, 3, 4, 5, 6, 1])

        let looping = trim(restored.state, handle: .trailing, delta: 1)
        XCTAssertEqual(looping.playbackCount, 2)
        XCTAssertEqual(frames(for: looping), [2, 3, 4, 5, 6, 1, 2])
    }

    func testLeadingExtensionWrapsBeforeFramesInsteadOfRestartingAtSourceStart() {
        let initial = state(sourceRange: 1...5, timelineDuration: 5, timelineStart: 2)

        let extended = trim(initial, handle: .leading, delta: -2)

        XCTAssertEqual(extended.state.timelineStart, 0, accuracy: 0.0001)
        XCTAssertEqual(extended.state.timelineDuration, 7, accuracy: 0.0001)
        XCTAssertEqual(extended.state.firstPlaybackOffset, 3, accuracy: 0.0001)
        XCTAssertEqual(extended.playbackCount, 2)
        XCTAssertEqual(frames(for: extended), [4, 5, 1, 2, 3, 4, 5])
    }

    func testTrailingExtensionStillAppendsFramesFromInspectorRangeStart() {
        let initial = state(sourceRange: 1...5, timelineDuration: 5, timelineStart: 2)

        let extended = trim(initial, handle: .trailing, delta: 2)

        XCTAssertEqual(extended.state.firstPlaybackOffset, 0, accuracy: 0.0001)
        XCTAssertEqual(extended.playbackCount, 2)
        XCTAssertEqual(frames(for: extended), [1, 2, 3, 4, 5, 1, 2])
    }

    func testLoopBoundariesAccountForFirstPlaybackOffset() {
        XCTAssertEqual(
            TimelinePlaybackRules.loopBoundaryOffsets(
                firstPlaybackOffset: 3,
                cycleDuration: 5,
                playbackCount: 2
            ),
            [2]
        )
        XCTAssertEqual(
            TimelinePlaybackRules.loopBoundaryOffsets(
                firstPlaybackOffset: 3,
                cycleDuration: 5,
                playbackCount: 3
            ),
            [2, 7]
        )
        let rateAdjustedOffsets = TimelinePlaybackRules.loopBoundaryOffsets(
            firstPlaybackOffset: 1,
            cycleDuration: 2,
            playbackCount: 2,
            playbackRate: 2
        )
        XCTAssertEqual(rateAdjustedOffsets.count, 1)
        XCTAssertEqual(rateAdjustedOffsets[0], 1.5, accuracy: 0.0001)
    }

    func testLoopAfterLeadingTrimWrapsToInspectorRangeStart() {
        let initial = state(sourceRange: 1...6, timelineDuration: 6)
        let leading = trim(initial, handle: .leading, delta: 1)
        let looping = trim(leading.state, handle: .trailing, delta: 2)

        XCTAssertEqual(looping.playbackCount, 2)
        XCTAssertEqual(frames(for: looping), [2, 3, 4, 5, 6, 1, 2])
    }

    func testSourceTimeUsesOffsetOnlyForFirstLoopPass() {
        let source = SourcePlaybackRange(duration: 6, start: 0, end: 6)

        XCTAssertEqual(
            source.sourceTime(at: 0, phase: 1, looping: true),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            source.sourceTime(at: 5, phase: 1, looping: true),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            source.sourceTime(at: 6, phase: 1, looping: true),
            1,
            accuracy: 0.0001
        )
    }

    func testInspectorRangeStartControlsLoopStart() {
        let initial = state(sourceRange: 2...4, timelineDuration: 3)

        let extended = trim(initial, handle: .trailing, delta: 1)

        XCTAssertEqual(extended.playbackCount, 2)
        XCTAssertEqual(
            TimelinePlaybackRules.frames(
                from: sourceFrames,
                sourceRange: 2...4,
                playbackFrameCount: 4
            ),
            [2, 3, 4, 2]
        )
    }

    func testTimelineTrimNeverChangesInspectorSourceRange() {
        let initial = state(sourceRange: 1...4, timelineDuration: 4)

        let leading = trim(initial, handle: .leading, delta: -2)
        let trailing = trim(initial, handle: .trailing, delta: 3)

        XCTAssertEqual(leading.state.sourceRange.start, 0)
        XCTAssertEqual(leading.state.sourceRange.end, 4)
        XCTAssertEqual(trailing.state.sourceRange.start, 0)
        XCTAssertEqual(trailing.state.sourceRange.end, 4)
    }

    func testStaticLeadingAndTrailingHandlesOnlyChangeTimelineWindow() {
        let initial = TimelineStaticTiming(start: 1, end: 5)

        let leading = TimelinePlaybackRules.trimStatic(
            initial,
            handle: .leading,
            delta: 1
        )
        let trailing = TimelinePlaybackRules.trimStatic(
            initial,
            handle: .trailing,
            delta: -1
        )

        XCTAssertEqual(leading, TimelineStaticTiming(start: 2, end: 5))
        XCTAssertEqual(trailing, TimelineStaticTiming(start: 1, end: 4))
    }

    func testStaticLeadingHandleCanExtendToTimelineStartAndTrailingHandleKeepsMinimumDuration() {
        let initial = TimelineStaticTiming(start: 2, end: 3)

        let extended = TimelinePlaybackRules.trimStatic(
            initial,
            handle: .leading,
            delta: -5
        )
        let collapsed = TimelinePlaybackRules.trimStatic(
            initial,
            handle: .trailing,
            delta: -5
        )

        XCTAssertEqual(extended, TimelineStaticTiming(start: 0, end: 3))
        XCTAssertEqual(collapsed.duration, 0.1, accuracy: 0.0001)
        XCTAssertEqual(collapsed.start, 2, accuracy: 0.0001)
    }

    private func state(
        sourceRange: ClosedRange<Int>,
        timelineDuration: TimeInterval,
        timelineStart: TimeInterval = 0
    ) -> TimelinePlaybackState {
        TimelinePlaybackState(
            sourceRange: SourcePlaybackRange(
                duration: max(5, TimeInterval(sourceRange.upperBound)),
                start: TimeInterval(sourceRange.lowerBound - 1),
                end: TimeInterval(sourceRange.upperBound)
            ),
            timelineStart: timelineStart,
            timelineEnd: timelineStart + timelineDuration
        )
    }

    private func trim(
        _ state: TimelinePlaybackState,
        handle: TimelineTrimHandle,
        delta: TimeInterval
    ) -> TimelineTrimResult {
        TimelinePlaybackRules.trim(
            state,
            handle: handle,
            delta: delta,
            playbackRate: 1
        )
    }

    private func frames(for result: TimelineTrimResult) -> [Int] {
        TimelinePlaybackRules.frames(
            from: sourceFrames,
            sourceRange: Int(result.state.sourceRange.start + 1)...Int(result.state.sourceRange.end),
            playbackFrameCount: Int(result.state.timelineDuration),
            firstPlaybackOffsetFrame: Int(result.state.firstPlaybackOffset)
        )
    }
}
