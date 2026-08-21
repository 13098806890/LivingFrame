import LivingFrameCore
import SwiftUI

/// 时间轴（参考剪映/CapCut 与 iPhone 视频编辑器）：
/// - 左侧固定轨道标识，右侧为可横向/纵向滚动的多轨区域
/// - 顶部刻度尺，素材条使用缩略图胶片带和明显的选中态
/// - 播放头有较大的拖动热区，刻度尺支持直接拖动定位
/// - 双指捏合缩放时间刻度（1x~8x）
/// - 拖动整体移动（就近磁吸对齐），左右边缘手柄裁剪开始/消失时间
struct TimelineView: View {
    @EnvironmentObject private var appState: AppState

    private let trackGutterWidth: CGFloat = 38
    private let rowHeight: CGFloat = 42
    private let rowSpacing: CGFloat = 4
    private let rulerHeight: CGFloat = 26
    /// 时间轴缩放（1x = 全时长铺满，8x = 放大到帧级）
    @State private var zoom: CGFloat = 1
    @State private var lastPinchZoom: CGFloat = 1
    @State private var elementDragSession: ElementDragSession?
    @State private var audioDragAnchors: [UUID: TimeInterval] = [:]
    @State private var playheadDragStart: TimeInterval?
    @State private var isScrubbing = false
    /// 直接操作轨道时锁住外层 ScrollView，避免轨道内容跟着手势整体平移。
    @State private var isTimelineManipulating = false
    /// 时间轴显示刻度的基准时长只增不减，避免缩短单个素材时整条时间轴突然重排。
    @State private var timelineScaleDuration: TimeInterval = 1

    private struct ElementDragAnchor {
        let start: TimeInterval
        let end: TimeInterval
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
    }

    private struct ElementTimelineMetrics {
        let outerStart: CGFloat
        let barWidth: CGFloat
        let activeOffset: CGFloat
        let activeWidth: CGFloat
    }

    private enum ElementDragMode {
        case move
        case trimStart
        case trimEnd
    }

    /// 一次拖拽从按下到抬起只使用这一份快照，避免素材条重绘后重新判断命中区域。
    private struct ElementDragSession {
        let id: UUID
        let mode: ElementDragMode
        let anchor: ElementDragAnchor
        let secondsPerPoint: CGFloat
    }

    private let maxTimelineHeight: CGFloat = 188

    private var rows: Int {
        guard let comp = appState.composition else { return 0 }
        return comp.elements.count + comp.audioClips.count
    }

    private var totalHeight: CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowSpacing
    }

    /// 每像素对应的秒数（缩放后）
    private func secondsPerPoint(_ width: CGFloat) -> CGFloat {
        let duration = displayedTimelineDuration()
        return (duration / width) / zoom
    }

    /// 时间轴显示完整素材内容，即使当前播放区间已经被裁短。
    private func displayedTimelineDuration() -> TimeInterval {
        guard let comp = appState.composition else {
            return max(timelineScaleDuration, 0.1)
        }
        let fullContentEnd = comp.elements.map(fullContentEndTime).max() ?? 0
        return max(comp.duration, fullContentEnd, timelineScaleDuration, 0.1)
    }

    private func fullContentEndTime(_ element: CompositionElement) -> TimeInterval {
        guard case .clip(let clipID) = element.kind,
              let clip = FrameCache.shared.clip(id: clipID) else {
            return element.endTime
        }
        let speed = max(clip.playbackSpeed, 0.01)
        let sourceStart = min(max(element.sourceStartTime, 0), clip.activeDuration)
        return element.startTime - sourceStart / speed + clip.activeDuration / speed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            timelineHeader

            if let comp = appState.composition, !comp.elements.isEmpty || !comp.audioClips.isEmpty {
                GeometryReader { geo in
                    // 给左侧轨道标识预留固定宽度，时间内容从同一条左边线开始。
                    let viewportWidth = max(geo.size.width - trackGutterWidth - 8, 1)
                    let contentWidth = max(viewportWidth, viewportWidth * zoom)
                    let contentHeight = rulerHeight + totalHeight
                    let spp = secondsPerPoint(viewportWidth)
                    // 时间轴面板本身固定不做纵向平移；只有放大时间轴后，
                    // 内容超出视口时才允许横向查看，避免拖空白区域时整块轨道跟手移动。
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 8) {
                            trackGutter(comp)

                            ZStack(alignment: .topLeading) {
                                ruler(width: viewportWidth, spp: spp)
                                    .frame(width: contentWidth, height: rulerHeight, alignment: .leading)

                                // 元素行
                                ForEach(Array(comp.elements.enumerated()), id: \.element.id) { i, element in
                                    elementRow(element, spp: spp)
                                        .position(x: rowX(element, spp: spp), y: rulerHeight + rowCenterY(i))
                                }

                                // 音频行（每条音轨一行，元素行之下依次排开）
                                ForEach(Array(comp.audioClips.enumerated()), id: \.element.id) { i, audio in
                                    audioRow(audio, spp: spp)
                                        .position(x: audioX(audio, spp: spp), y: rulerHeight + rowCenterY(comp.elements.count + i))
                                }

                                // 播放头（可拖动定位）
                                playhead(spp: spp, height: totalHeight, contentWidth: contentWidth)
                            }
                            .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                        }
                        .frame(width: trackGutterWidth + 8 + contentWidth, height: contentHeight, alignment: .topLeading)
                        .simultaneousGesture(pinchZoomGesture)
                    }
                    .scrollDisabled(contentWidth <= viewportWidth + 0.5 || isTimelineManipulating)
                    .frame(width: geo.size.width, height: min(maxTimelineHeight, contentHeight), alignment: .topLeading)
                }
                .frame(height: min(maxTimelineHeight, rulerHeight + totalHeight))
            } else {
                Text("添加素材后显示时间轴")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 40)
            }
        }
        .onAppear {
            syncTimelineScaleDuration()
        }
        .onChange(of: appState.composition?.duration) { _, newDuration in
            timelineScaleDuration = max(timelineScaleDuration, newDuration ?? 1, 0.1)
        }
        .onChange(of: appState.composition?.id) { _, _ in
            timelineScaleDuration = max(appState.composition?.duration ?? 1, 0.1)
        }
    }

    private func syncTimelineScaleDuration() {
        timelineScaleDuration = max(timelineScaleDuration, displayedTimelineDuration(), 0.1)
    }

    private var timelineHeader: some View {
        HStack(spacing: 8) {
            Label("时间轴", systemImage: "film.stack")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LF.accentDeep)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Button {
                    zoom = max(1, zoom - 0.5)
                    lastPinchZoom = zoom
                } label: {
                    Image(systemName: "minus")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LF.textSecondary)

                Text("\(Int(zoom * 100))%")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(LF.textSecondary)
                    .frame(minWidth: 36)

                Button {
                    zoom = min(8, zoom + 0.5)
                    lastPinchZoom = zoom
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LF.textSecondary)
            }
            .background(Color.white.opacity(0.72), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(LF.accent.opacity(0.12), lineWidth: 1)
            }

            Text(String(format: "%.2f / %.1f s", appState.currentTime, appState.composition?.duration ?? 0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(LF.textSecondary)

            Button {
                appState.isReversed.toggle()
            } label: {
                Image(systemName: "arrow.right.arrow.left")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        appState.isReversed ? LF.accentSoft : Color.clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.isReversed ? LF.accentDeep : LF.textSecondary)
            .accessibilityLabel("倒放")
        }
    }

    // MARK: - 缩放（双指捏合）

    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(max(lastPinchZoom * value.magnification, 1), 8)
            }
            .onEnded { _ in
                lastPinchZoom = zoom
            }
    }

    // MARK: - 刻度尺

    private func ruler(width: CGFloat, spp: CGFloat) -> some View {
        let duration = displayedTimelineDuration()
        // 刻度间隔：保证标签间距 ≥ 48pt
        let candidates: [CGFloat] = [0.5, 1, 2, 5, 10, 15, 30]
        let step = candidates.first { $0 / spp >= 48 } ?? 60
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(LF.accentSoft.opacity(0.45))
            HStack(spacing: 0) {
                ForEach(0..<Int(duration / step) + 1, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle()
                            .fill(LF.accentDeep.opacity(0.58))
                            .frame(width: 1, height: 9)
                            Text("\(Int(CGFloat(i) * step))s")
                                .font(.system(size: 8))
                                .foregroundStyle(LF.accentDeep.opacity(0.82))
                    }
                    .frame(width: step / spp, alignment: .leading)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(scrubGesture(spp: spp))
        .clipped()
    }

    private func trackGutter(_ comp: Composition) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)

            VStack(spacing: rowSpacing) {
                ForEach(Array(comp.elements.enumerated()), id: \.element.id) { _, element in
                    trackBadge(symbol: elementSymbol(element))
                        .frame(height: rowHeight)
                }
                ForEach(comp.audioClips) { _ in
                    trackBadge(symbol: "waveform")
                        .frame(height: rowHeight)
                }
            }
        }
        .frame(width: trackGutterWidth, height: rulerHeight + totalHeight, alignment: .top)
    }

    private func trackBadge(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.78))
            .frame(width: 30, height: 30)
    }

    // MARK: - 行定位

    private func rowCenterY(_ i: Int) -> CGFloat {
        CGFloat(i) * (rowHeight + rowSpacing) + rowHeight / 2
    }

    private func rowX(_ element: CompositionElement, spp: CGFloat) -> CGFloat {
        let metrics = elementMetrics(element, spp: spp)
        return metrics.outerStart + metrics.barWidth / 2
    }

    private func audioX(_ clip: AudioClip, spp: CGFloat) -> CGFloat {
        let barWidth = max(clip.duration / spp, 20)
        return clip.startTime / spp + barWidth / 2
    }

    private func elementMetrics(_ element: CompositionElement, spp: CGFloat) -> ElementTimelineMetrics {
        guard case .clip(let clipID) = element.kind,
              let clip = FrameCache.shared.clip(id: clipID) else {
            let activeWidth = max((element.endTime - element.startTime) / spp, 20)
            return ElementTimelineMetrics(
                outerStart: element.startTime / spp,
                barWidth: activeWidth,
                activeOffset: 0,
                activeWidth: activeWidth
            )
        }

        let speed = max(clip.playbackSpeed, 0.01)
        let sourceDuration = max(clip.activeDuration, 0.001)
        let sourceStart = min(max(element.sourceStartTime, 0), sourceDuration)
        let fullTimelineDuration = sourceDuration / speed
        // 有效区域的视觉边界只由时间轴上的 start/end 决定。
        // sourceStart/sourceEnd 只负责源素材入点/出点，不能再参与有效条宽度计算，
        // 否则右边界减少时会同时改变有效区的两套几何量，产生“缩短两倍”的错觉。
        let activeTimelineDuration = max(element.endTime - element.startTime, 0.1)
        let barWidth = max(fullTimelineDuration / spp, 20)
        let activeOffset = min(
            max(sourceStart / speed / spp, 0),
            max(0, barWidth - 20)
        )
        let activeWidth = min(
            max(activeTimelineDuration / spp, 20),
            barWidth
        )
        return ElementTimelineMetrics(
            outerStart: element.startTime / spp - activeOffset,
            barWidth: barWidth,
            activeOffset: activeOffset,
            activeWidth: activeWidth
        )
    }

    // MARK: - 元素行（帧缩略图拼贴）

    private func elementRow(_ element: CompositionElement, spp: CGFloat) -> some View {
        let metrics = elementMetrics(element, spp: spp)
        let barWidth = metrics.barWidth
        let barHeight = rowHeight - 8
        let isSelected = appState.isElementSelected(element.id)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color(for: element).opacity(0.22))
                .frame(width: barWidth, height: barHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? LF.accent : .clear, lineWidth: 2.5)
                }
            // 帧缩略图拼贴：人物素材和贴纸都在时间轴上显示实际帧。
            if case .clip(let clipID) = element.kind,
               let clip = FrameCache.shared.clip(id: clipID) {
                let fullStrip = thumbnails(for: clip, barWidth: barWidth, spp: spp)
                    .frame(width: barWidth, height: barHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                ZStack(alignment: .leading) {
                    fullStrip.opacity(0.28)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color(for: element).opacity(0.46))
                        .frame(width: metrics.activeWidth, height: barHeight)
                        .offset(x: metrics.activeOffset)
                    fullStrip
                        .mask {
                            HStack(spacing: 0) {
                                Color.clear.frame(width: metrics.activeOffset)
                                Color.white.frame(width: metrics.activeWidth)
                                Color.clear.frame(width: max(0, barWidth - metrics.activeOffset - metrics.activeWidth))
                            }
                            .frame(width: barWidth, height: barHeight, alignment: .leading)
                        }
                    LinearGradient(
                        colors: [.black.opacity(0.02), .black.opacity(0.24)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: barWidth, height: barHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .frame(width: barWidth, height: barHeight)
                .allowsHitTesting(false)
            } else if case .decoration(let decorationID) = element.kind {
                StickerTimelineStrip(
                    decorationID: decorationID,
                    width: barWidth,
                    height: barHeight
                )
                .frame(width: barWidth, height: barHeight, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
            }

            // 条内标签，帮助用户在多轨道时快速识别素材。
            HStack(spacing: 4) {
                Image(systemName: elementSymbol(element))
                    .font(.system(size: 9, weight: .bold))
                Text(displayName(for: element))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
                .foregroundStyle(.white.opacity(0.96))
            .padding(.horizontal, 8)
            .frame(width: max(barWidth - 24, 0), height: barHeight, alignment: .leading)
            .allowsHitTesting(false)

            // 左右裁剪手柄（仅负责视觉，不阻挡热区）
            HStack(spacing: 0) {
                Color.clear.frame(width: metrics.activeOffset)
                Capsule()
                    .fill(LF.accent)
                    .frame(width: 4, height: rowHeight - 18)
                Spacer()
                    .frame(width: max(0, metrics.activeWidth - 8))
                Capsule()
                    .fill(LF.accent)
                    .frame(width: 4, height: rowHeight - 18)
            }
            // 必须左对齐：barWidth 是完整素材范围，不能把缩短后的有效区间居中。
            .frame(width: barWidth, height: barHeight, alignment: .leading)
            .allowsHitTesting(false)
        }
        .frame(width: barWidth, height: barHeight)
        .contentShape(Rectangle())
        .gesture(elementDragGesture(element, spp: spp))
        .onTapGesture {
            appState.selectElement(element.id)
        }
    }

    /// 素材条内帧缩略图拼贴（按条宽平铺，最多 24 个）
    private func thumbnails(for clip: SegmentedClip, barWidth: CGFloat, spp: CGFloat) -> some View {
        let thumbW: CGFloat = 26
        let count = max(Int(barWidth / thumbW), 1)
        let visibleCount = min(count, 24)
        let cellWidth = barWidth / CGFloat(visibleCount)
        let indices = (0..<visibleCount).map { i -> Int in
            let active = clip.activeFrameIndices
            guard !active.isEmpty else { return 0 }
            let t = CGFloat(i) / CGFloat(max(visibleCount, 1)) * CGFloat(active.count)
            let idx = min(max(Int(t), 0), active.count - 1)
            return active[idx]
        }
        return HStack(spacing: 1) {
            ForEach(0..<indices.count, id: \.self) { i in
                ClipThumbnailView(clip: clip, index: indices[i], maxPixelSize: 60)
                .frame(width: cellWidth, height: rowHeight - 10)
                .clipped()
            }
        }
        .frame(width: barWidth, alignment: .leading)
    }

    // MARK: - 音频行

    private func audioRow(_ clip: AudioClip, spp: CGFloat) -> some View {
        let barWidth = max(clip.duration / spp, 20)
        let isSelected = appState.selectedAudioID == clip.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.teal.opacity(0.92), Color.cyan.opacity(0.62)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: barWidth, height: rowHeight - 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? LF.accent : .clear, lineWidth: 2.5)
                }
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                Text(String(format: "%.1f", clip.volume))
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 6)
        }
        .frame(width: barWidth, height: rowHeight - 8)
        .contentShape(Rectangle())
        .gesture(dragAudio(clip, spp: spp))
        .onTapGesture {
            appState.selectedAudioID = clip.id
            appState.clearElementSelection()
        }
    }

    // MARK: - 播放头（可拖动）

    private func playhead(spp: CGFloat, height: CGFloat, contentWidth: CGFloat) -> some View {
        let x = appState.currentTime / spp
        // 刻度尺的 0 秒就是内容区域的 x=0；播放头不能再人为留出 14pt 边距，
        // 否则最左侧时间刻度和竖线会错开。
        let clampedX = min(max(x, 0), contentWidth)
        let totalHeight = rulerHeight + height
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(LF.accent)
                .frame(width: 3, height: totalHeight)
                .allowsHitTesting(false)
            TimelinePlayheadMarker()
                .fill(LF.accent)
                .frame(width: 16, height: 12)
                .allowsHitTesting(false)
        }
            .frame(width: 16, height: totalHeight)
            // 只让顶部播放头帽子接收拖动，竖线本身不再挡住素材条的裁剪手柄。
            .overlay(alignment: .top) {
                Color.clear
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                    .gesture(playheadDragGesture(spp: spp))
            }
            .position(x: clampedX, y: totalHeight / 2)
    }

    private func playheadDragGesture(spp: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if playheadDragStart == nil {
                    playheadDragStart = appState.currentTime
                    isTimelineManipulating = true
                }
                appState.pause()
                let t = (playheadDragStart ?? appState.currentTime) + value.translation.width * spp
                appState.seek(to: t)
            }
            .onEnded { _ in
                playheadDragStart = nil
                isTimelineManipulating = false
            }
    }

    /// 刻度尺拖动定位，行为接近剪映在时间尺上拖动播放头。
    private func scrubGesture(spp: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    isTimelineManipulating = true
                    appState.pause()
                }
                appState.seek(to: value.location.x * spp)
            }
            .onEnded { _ in
                isScrubbing = false
                isTimelineManipulating = false
            }
    }

    // MARK: - 拖动（移动与裁剪分离手势）

    /// 一条素材只使用一个拖拽手势；按下时确定模式，整个手势期间不再重新命中。
    private func elementDragGesture(_ element: CompositionElement, spp: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if elementDragSession == nil {
                    let metrics = elementMetrics(element, spp: spp)
                    guard let mode = dragMode(at: value.startLocation.x, metrics: metrics) else { return }
                    elementDragSession = ElementDragSession(
                        id: element.id,
                        mode: mode,
                        anchor: ElementDragAnchor(
                            start: element.startTime,
                            end: element.endTime,
                            sourceStart: element.sourceStartTime,
                            sourceEnd: element.sourceEndTime
                        ),
                        secondsPerPoint: spp
                    )
                    isTimelineManipulating = true
                }

                guard let session = elementDragSession,
                      session.id == element.id,
                      let current = appState.composition?.elements.first(where: { $0.id == element.id }) else { return }
                let delta = value.translation.width * session.secondsPerPoint
                switch session.mode {
                case .move:
                    guard let comp = appState.composition else { return }
                    let duration = session.anchor.end - session.anchor.start
                    let newStart = snap(
                        max(session.anchor.start + delta, 0),
                        excluding: element.id,
                        comp: comp
                    )
                    appState.updateElement(element.id, { element in
                        element.startTime = newStart
                        element.endTime = newStart + duration
                    }, recomputeDuration: false)
                case .trimStart:
                    trimStart(current, anchor: session.anchor, delta: delta)
                case .trimEnd:
                    trimEnd(current, anchor: session.anchor, delta: delta)
                }
            }
            .onEnded { _ in
                elementDragSession = nil
                isTimelineManipulating = false
                appState.recomputeDuration()
            }
    }

    private func dragMode(at x: CGFloat, metrics: ElementTimelineMetrics) -> ElementDragMode? {
        let handleWidth = min(24, max(metrics.activeWidth / 2, 12))
        let middleWidth = max(metrics.activeWidth - handleWidth * 2, 0)
        let leftStart = metrics.activeOffset
        let leftEnd = leftStart + handleWidth
        let rightStart = leftEnd + middleWidth
        let rightEnd = rightStart + handleWidth

        if x >= leftStart, x < leftEnd { return .trimStart }
        if x >= rightStart, x <= rightEnd { return .trimEnd }
        if middleWidth > 0, x >= leftEnd, x < rightStart { return .move }
        return nil
    }

    private func trimStart(_ element: CompositionElement, anchor: ElementDragAnchor, delta: CGFloat) {
        guard case .clip(let clipID) = element.kind,
              let clip = FrameCache.shared.clip(id: clipID) else {
            let newStart = min(max(anchor.start + delta, 0), anchor.end - 0.1)
            appState.updateElement(element.id, { element in
                element.startTime = newStart
            }, recomputeDuration: false)
            return
        }

        let speed = max(clip.playbackSpeed, 0.01)
        let sourceDuration = max(clip.activeDuration, 0.001)
        let sourceEnd = anchor.sourceEnd.isFinite
            ? min(max(anchor.sourceEnd, anchor.sourceStart), sourceDuration)
            : sourceDuration
        let minimumSourceSpan = min(0.1 * speed, sourceDuration)
        let minimumSourceStart = max(0, sourceEnd - anchor.end * speed)
        let maximumSourceStart = max(minimumSourceStart, sourceEnd - minimumSourceSpan)
        let newSourceStart = min(
            max(anchor.sourceStart + delta * speed, minimumSourceStart),
            maximumSourceStart
        )
        let newStart = anchor.end - (sourceEnd - newSourceStart) / speed
        appState.updateElement(element.id, { element in
            element.startTime = max(newStart, 0)
            element.sourceStartTime = newSourceStart
            element.sourceEndTime = sourceEnd
        }, recomputeDuration: false)
    }

    private func trimEnd(_ element: CompositionElement, anchor: ElementDragAnchor, delta: CGFloat) {
        guard case .clip(let clipID) = element.kind,
              let clip = FrameCache.shared.clip(id: clipID) else {
            let newEnd = max(anchor.start + 0.1, anchor.end + delta)
            appState.updateElement(element.id, { element in
                element.endTime = newEnd
            }, recomputeDuration: false)
            return
        }

        let speed = max(clip.playbackSpeed, 0.01)
        let sourceDuration = max(clip.activeDuration, 0.001)
        let sourceStart = min(max(anchor.sourceStart, 0), sourceDuration)
        let minimumSourceSpan = min(0.1 * speed, sourceDuration)
        let minimumSourceEnd = min(sourceStart + minimumSourceSpan, sourceDuration)
        let oldSourceEnd = anchor.sourceEnd.isFinite
            ? min(max(anchor.sourceEnd, minimumSourceEnd), sourceDuration)
            : sourceDuration
        let newSourceEnd = min(
            max(oldSourceEnd + delta * speed, minimumSourceEnd),
            sourceDuration
        )
        let newEnd = anchor.start + (newSourceEnd - sourceStart) / speed
        appState.updateElement(element.id, { element in
            element.startTime = anchor.start
            element.endTime = max(newEnd, anchor.start + 0.1)
            element.sourceStartTime = sourceStart
            element.sourceEndTime = newSourceEnd
        }, recomputeDuration: false)
    }

    /// 就近磁吸：吸附到轨道起点/其他元素边缘/播放头
    private func snap(_ value: CGFloat, excluding elementID: UUID, comp: Composition) -> CGFloat {
        var points: [CGFloat] = [0, appState.currentTime]
        points += comp.elements.compactMap { e in
            e.id == elementID ? nil : [e.startTime, e.endTime]
        }.flatMap { $0 }
        points += comp.audioClips.flatMap { [$0.startTime, $0.startTime + $0.duration] }
        let threshold: CGFloat = 0.1
        guard let nearest = points.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) < threshold else { return value }
        return nearest
    }

    private func dragAudio(_ clip: AudioClip, spp: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition else { return }
                let anchor = audioDragAnchors[clip.id] ?? {
                    if appState.isPlaying { appState.pause() }
                    audioDragAnchors[clip.id] = clip.startTime
                    isTimelineManipulating = true
                    return clip.startTime
                }()
                let delta = value.translation.width * spp
                var newStart = min(max(anchor + delta, 0), max(0, comp.duration - clip.duration))
                let points: [CGFloat] = [0] + comp.elements.flatMap { [$0.startTime, $0.endTime] }
                let threshold: CGFloat = 0.1
                if let nearest = points.min(by: { abs($0 - newStart) < abs($1 - newStart) }),
                   abs(nearest - newStart) < threshold {
                    newStart = nearest
                }
                appState.updateAudio(clip.id, { clip in
                    clip.startTime = newStart
                }, syncPreview: false)
            }
            .onEnded { _ in
                audioDragAnchors.removeValue(forKey: clip.id)
                isTimelineManipulating = false
                appState.finishAudioEdit()
            }
    }

    private func elementSymbol(_ element: CompositionElement) -> String {
        switch element.kind {
        case .clip: "person.crop.rectangle"
        case .decoration: "rectangle.badge.plus"
        case .effect: "sparkles"
        case .text: "textformat"
        }
    }

    private func displayName(for element: CompositionElement) -> String {
        guard case .decoration(let decorationID) = element.kind else {
            return element.name
        }
        let catalogName = DecorationRenderer.stickerName(for: decorationID)
        return catalogName == decorationID ? element.name : catalogName
    }

    private func color(for element: CompositionElement) -> Color {
        switch element.kind {
        case .clip: Color(hex: "79C9EC").opacity(0.82)
        case .decoration: LF.accentDeep.opacity(0.82)
        case .effect: Color.pink.opacity(0.75)
        case .text: Color.blue.opacity(0.75)
        }
    }
}

/// 贴纸时间轴帧条：异步读取已缓存的贴纸帧，并沿时间轴平铺显示。
private struct StickerTimelineStrip: View {
    let decorationID: String
    let width: CGFloat
    let height: CGFloat

    @State private var frames: [CGImage] = []

    private var cellCount: Int {
        min(max(Int(width / 26), 1), 24)
    }

    var body: some View {
        Group {
            if frames.isEmpty {
                Color.clear
            } else {
                let cellWidth = width / CGFloat(cellCount)
                HStack(spacing: 1) {
                    ForEach(0..<cellCount, id: \.self) { index in
                        Image(decorative: frames[index % frames.count], scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: cellWidth, height: height)
                            .clipped()
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
            }
        }
        .task(id: decorationID) {
            let id = decorationID
            let loaded = await Task.detached(priority: .utility) {
                DecorationRenderer().previewFrames(for: id)
            }.value
            guard !Task.isCancelled else { return }
            frames = loaded
        }
        .onDisappear {
            frames.removeAll(keepingCapacity: false)
        }
    }
}

private struct TimelinePlayheadMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
