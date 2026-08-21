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

    /// 拖拽必须在不会随素材条一起移动的坐标系中计算。
    /// 如果使用 DragGesture 默认的局部坐标系，素材条每次更新位置后都会改变下一帧的
    /// translation 基准，形成“手指向右、素材左右来回跳”的反馈循环。
    private static let contentCoordinateSpace = "living-frame.timeline-content"
    private static let layerGutterCoordinateSpace = "living-frame.timeline-layer-gutter"

    private let trackGutterWidth: CGFloat = 38
    private let rowHeight: CGFloat = 42
    /// 轨道之间保持极紧凑的分隔，避免素材较多时浪费垂直空间。
    private let rowSpacing: CGFloat = 1
    private let rulerHeight: CGFloat = 26
    /// 为 0s 标签预留半个标签宽度，让标签中心、主刻度线和播放头共用同一 x 坐标。
    private let timelineLeadingInset: CGFloat = 18
    /// 给最右侧 iOS 风格裁剪柄预留可见空间，避免贴到时间轴边界后被裁掉。
    private let timelineTrailingInset: CGFloat = 18
    /// 时间轴缩放（1x = 全时长铺满，8x = 放大到帧级）
    @State private var zoom: CGFloat = 1
    @State private var lastPinchZoom: CGFloat = 1
    @State private var elementDragSession: ElementDragSession?
    @State private var layerReorderSession: LayerReorderSession?
    @State private var audioDragAnchors: [UUID: TimeInterval] = [:]
    @State private var playheadDragStart: TimeInterval?
    @State private var isScrubbing = false
    /// 直接操作轨道时锁住外层 ScrollView，避免轨道内容跟着手势整体平移。
    @State private var isTimelineManipulating = false
    /// 拖拽期间冻结的刻度基准：操作中允许内容把它撑长，松手后再按实际内容收缩，
    /// 避免素材跟手移动时刻度反复重排。
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

    private struct LayerReorderSession {
        let id: UUID
        let initialOrder: [UUID]
        let startIndex: Int
        var currentIndex: Int
    }

    private let maxTimelineHeight: CGFloat = 188

    private var rows: Int {
        guard let comp = appState.composition else { return 0 }
        return comp.elements.count + comp.audioClips.count
    }

    private var totalHeight: CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowSpacing
    }

    /// 时间轴从上到下直接对应画布从上层到下层；同层级的旧工程按插入顺序稳定显示。
    private func timelineElements(_ comp: Composition) -> [CompositionElement] {
        comp.elements.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.zIndex != rhs.element.zIndex {
                    return lhs.element.zIndex > rhs.element.zIndex
                }
                return lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    /// 每像素对应的秒数（缩放后）
    private func secondsPerPoint(_ width: CGFloat) -> CGFloat {
        let duration = displayedTimelineDuration()
        return (duration / width) / zoom
    }

    /// 时间轴显示完整素材内容，即使当前播放区间已经被裁短。
    private func displayedTimelineDuration() -> TimeInterval {
        max(contentTimelineDuration(), timelineScaleDuration, 0.1)
    }

    /// 不包含冻结基准的真实内容范围，用于拖拽结束后恢复合适的刻度上限。
    private func contentTimelineDuration() -> TimeInterval {
        guard let comp = appState.composition else { return 0.1 }
        let fullContentEnd = comp.elements.map(fullContentEndTime).max() ?? 0
        return max(comp.duration, fullContentEnd, 0.1)
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
                    let timeViewportWidth = max(
                        viewportWidth - timelineLeadingInset - timelineTrailingInset,
                        1
                    )
                    let contentWidth = timelineLeadingInset
                        + max(timeViewportWidth, timeViewportWidth * zoom)
                        + timelineTrailingInset
                    let contentHeight = rulerHeight + totalHeight
                    let spp = secondsPerPoint(timeViewportWidth)
                    let orderedElements = timelineElements(comp)
                    // 轨道超过面板高度时由外层纵向滚动；右侧时间内容放大后再单独
                    // 横向滚动。这样左侧轨道标识会和素材行一起上下移动，却不会被
                    // 横向滚出视口。
                    ScrollView(.vertical, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 8) {
                            trackGutter(comp)

                            ScrollView(.horizontal, showsIndicators: false) {
                                ZStack(alignment: .topLeading) {
                                    ruler(width: viewportWidth, spp: spp)
                                        .frame(width: contentWidth, height: rulerHeight, alignment: .leading)

                                    // 元素行
                                    ForEach(Array(orderedElements.enumerated()), id: \.element.id) { i, element in
                                        elementRow(element, spp: spp)
                                            .position(x: rowX(element, spp: spp), y: rulerHeight + rowCenterY(i))
                                    }

                                    // 音频行（每条音轨一行，元素行之下依次排开）
                                    ForEach(Array(comp.audioClips.enumerated()), id: \.element.id) { i, audio in
                                        audioRow(audio, spp: spp)
                                            .position(x: audioX(audio, spp: spp), y: rulerHeight + rowCenterY(orderedElements.count + i))
                                    }

                                    // 播放头（可拖动定位）
                                    playhead(spp: spp, height: totalHeight, contentWidth: contentWidth)
                                }
                                .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                                .animation(
                                    .interactiveSpring(response: 0.28, dampingFraction: 0.82),
                                    value: orderedElements.map(\.id)
                                )
                                .coordinateSpace(name: Self.contentCoordinateSpace)
                            }
                            .scrollDisabled(isTimelineManipulating)
                            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                            .frame(width: viewportWidth, height: contentHeight, alignment: .topLeading)
                        }
                        .frame(width: geo.size.width, height: contentHeight, alignment: .topLeading)
                        .simultaneousGesture(pinchZoomGesture)
                    }
                    .scrollDisabled(isTimelineManipulating)
                    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
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
            settleTimelineScaleDuration()
        }
        .onChange(of: appState.composition?.duration) { _, _ in
            if isTimelineManipulating {
                growTimelineScaleDurationIfNeeded()
            } else {
                settleTimelineScaleDuration()
            }
        }
        .onChange(of: appState.composition?.id) { _, _ in
            settleTimelineScaleDuration()
        }
    }

    private func growTimelineScaleDurationIfNeeded() {
        timelineScaleDuration = max(timelineScaleDuration, contentTimelineDuration(), 1)
    }

    private func settleTimelineScaleDuration() {
        timelineScaleDuration = max(contentTimelineDuration(), 1)
    }

    private var timelineHeader: some View {
        HStack(spacing: 8) {
            Label("时间轴", systemImage: "film.stack")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.black)

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
                .foregroundStyle(Color.black)

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
                .foregroundStyle(appState.isReversed ? Color.black : LF.textSecondary)
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

    private func ruler(width _: CGFloat, spp: CGFloat) -> some View {
        let duration = displayedTimelineDuration()
        // 刻度间隔：保证标签间距 ≥ 48pt
        let candidates: [CGFloat] = [0.5, 1, 2, 5, 10, 15, 30]
        let step = candidates.first { $0 / spp >= 48 } ?? 60
        let majorCount = max(Int(ceil(duration / step)), 1)
        let majorWidth = step / spp
        let minorDivisions = 4
        let labelWidth: CGFloat = 34

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.08))

            ForEach(0...majorCount, id: \.self) { i in
                let majorX = timelineLeadingInset + CGFloat(i) * majorWidth

                // 所有标签都与对应主刻度线共用中心点，包括 0 秒。
                Rectangle()
                    .fill(Color.black.opacity(0.72))
                    .frame(width: 1, height: 9)
                    .offset(x: majorX - 0.5)

                Text(rulerTimeLabel(CGFloat(i) * step))
                    .font(.system(size: 8))
                    .foregroundStyle(Color.black)
                    .frame(
                        width: labelWidth,
                        alignment: .center
                    )
                    .offset(
                        x: majorX - labelWidth / 2,
                        y: 11
                    )

                // 每两个主刻度之间四等分；中间短线稍长，便于快速判断半刻度。
                if i < majorCount {
                    ForEach(1..<minorDivisions, id: \.self) { division in
                        let minorX = majorX
                            + majorWidth * CGFloat(division) / CGFloat(minorDivisions)
                        Rectangle()
                            .fill(Color.black.opacity(division == 2 ? 0.55 : 0.35))
                            .frame(width: 0.8, height: division == 2 ? 6 : 4)
                            .offset(x: minorX - 0.4)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(scrubGesture(spp: spp))
        .clipped()
    }

    private func rulerTimeLabel(_ seconds: CGFloat) -> String {
        if abs(seconds.rounded() - seconds) < 0.001 {
            return "\(Int(seconds.rounded()))s"
        }
        return String(format: "%.1fs", Double(seconds))
    }

    private func trackGutter(_ comp: Composition) -> some View {
        let orderedElements = timelineElements(comp)
        return VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)

            VStack(spacing: rowSpacing) {
                ForEach(orderedElements) { element in
                    layerTrackBadge(element)
                        .frame(height: rowHeight)
                }
                ForEach(comp.audioClips) { _ in
                    trackBadge(symbol: "waveform")
                        .frame(height: rowHeight)
                }
            }
        }
        .frame(width: trackGutterWidth, height: rulerHeight + totalHeight, alignment: .top)
        .coordinateSpace(name: Self.layerGutterCoordinateSpace)
    }

    private func layerTrackBadge(_ element: CompositionElement) -> some View {
        let isDragging = layerReorderSession?.id == element.id
        return HStack(spacing: 2) {
            Image(systemName: elementSymbol(element))
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(LF.textSecondary)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(isDragging ? LF.accentDeep : Color.black.opacity(0.78))
        .frame(width: 36, height: 30)
        .background(isDragging ? LF.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectElement(element.id)
        }
        .highPriorityGesture(layerReorderGesture(element))
        .accessibilityLabel("\(element.name)，上下拖动调整图层")
    }

    private func trackBadge(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.78))
            .frame(width: 30, height: 30)
    }

    /// 左侧轨道手柄只处理垂直层级调整，不与素材条的水平移动/裁剪手势竞争。
    private func layerReorderGesture(_ element: CompositionElement) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.layerGutterCoordinateSpace)))
            .onChanged { value in
                guard case let .second(true, dragValue?) = value else { return }

                if layerReorderSession == nil {
                    guard let comp = appState.composition else { return }
                    let order = timelineElements(comp).map(\.id)
                    guard let startIndex = order.firstIndex(of: element.id) else { return }
                    layerReorderSession = LayerReorderSession(
                        id: element.id,
                        initialOrder: order,
                        startIndex: startIndex,
                        currentIndex: startIndex
                    )
                    appState.selectElement(element.id)
                    isTimelineManipulating = true
                }

                guard var session = layerReorderSession,
                      session.id == element.id else { return }
                let rowStep = rowHeight + rowSpacing
                let offset = Int((dragValue.translation.height / rowStep).rounded())
                let targetIndex = min(
                    max(session.startIndex + offset, 0),
                    session.initialOrder.count - 1
                )
                guard targetIndex != session.currentIndex else { return }

                var reordered = session.initialOrder
                let movedID = reordered.remove(at: session.startIndex)
                reordered.insert(movedID, at: targetIndex)
                withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.82)) {
                    appState.setElementLayerOrder(topToBottom: reordered)
                }
                session.currentIndex = targetIndex
                layerReorderSession = session
            }
            .onEnded { _ in
                if let session = layerReorderSession {
                    LogStore.log(
                        "timeline.layerReorder id=\(session.id) "
                            + "from=\(session.startIndex) to=\(session.currentIndex)"
                    )
                }
                layerReorderSession = nil
                isTimelineManipulating = false
            }
    }

    // MARK: - 行定位

    private func rowCenterY(_ i: Int) -> CGFloat {
        CGFloat(i) * (rowHeight + rowSpacing) + rowHeight / 2
    }

    private func rowX(_ element: CompositionElement, spp: CGFloat) -> CGFloat {
        let metrics = elementMetrics(element, spp: spp)
        return timelineLeadingInset + metrics.outerStart + metrics.barWidth / 2
    }

    private func audioX(_ clip: AudioClip, spp: CGFloat) -> CGFloat {
        let barWidth = max(clip.duration / spp, 20)
        return timelineLeadingInset + clip.startTime / spp + barWidth / 2
    }

    private func elementMetrics(_ element: CompositionElement, spp: CGFloat) -> ElementTimelineMetrics {
        guard case .clip(let clipID) = element.kind,
              let clip = FrameCache.shared.clip(id: clipID) else {
            let activeDuration = max(element.endTime - element.startTime, 0.1)
            let cycleDuration: TimeInterval
            if case .decoration(let decorationID) = element.kind,
               let defaultDuration = DecorationRenderer.stickerDefinition(for: decorationID)?.defaultDuration,
               defaultDuration.isFinite, defaultDuration > 0 {
                cycleDuration = defaultDuration
            } else {
                cycleDuration = activeDuration
            }
            let activeWidth = max(activeDuration / spp, 20)
            let barWidth = max(max(cycleDuration, activeDuration) / spp, 20)
            return ElementTimelineMetrics(
                outerStart: element.startTime / spp,
                barWidth: barWidth,
                activeOffset: 0,
                activeWidth: activeWidth
            )
        }

        let speed = max(clip.playbackSpeed, 0.01)
        let sourceDuration = max(clip.activeDuration, 0.001)
        let sourceStart = min(max(element.sourceStartTime, 0), sourceDuration)
        let sourceEnd = element.sourceEndTime.isFinite
            ? min(max(element.sourceEndTime, sourceStart), sourceDuration)
            : sourceDuration
        let activeTimelineDuration = max(element.endTime - element.startTime, 0.1)
        let sourceCycleDuration = max((sourceEnd - sourceStart) / speed, 0.1)
        let isLooping = activeTimelineDuration > sourceCycleDuration + 0.001
        let activeOffset = isLooping ? 0 : max(sourceStart / speed / spp, 0)
        let cycleTimelineDuration = isLooping
            ? max(sourceEnd / speed, 0.1)
            : sourceCycleDuration
        let barWidth = max(
            (activeOffset * spp + max(cycleTimelineDuration, activeTimelineDuration)) / spp,
            20
        )
        let activeWidth = max(activeTimelineDuration / spp, 20)
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
        let isLoopTrimDragging = isLoopTrimActive(for: element.id)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color(for: element).opacity(0.22))
                .frame(width: barWidth, height: barHeight)
            // 帧缩略图拼贴：人物素材和贴纸都在时间轴上显示实际帧。
            if case .clip(let clipID) = element.kind,
               let clip = FrameCache.shared.clip(id: clipID) {
                let fullStrip = thumbnails(
                    for: clip,
                    element: element,
                    metrics: metrics,
                    barWidth: barWidth,
                    spp: spp
                )
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

            // 正常状态只用缩略图里的窄明暗接缝表示循环边界；不画贯穿素材的竖线。
            ForEach(loopBoundaryOffsets(element, metrics: metrics, spp: spp), id: \.self) { offset in
                if !isSelected {
                    LoopBoundarySeam(height: barHeight)
                        .offset(x: offset - 2)
                }
                if isSelected {
                    // 选中时才显示顶部两侧相向弧线，像两段胶片在此处轻轻接合。
                    LoopBoundaryJoinArc()
                        .stroke(
                            Color.black.opacity(0.58),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
                        )
                        .frame(width: 12, height: 6)
                        .offset(x: offset - 6, y: -(barHeight / 2) + 2)
                        .zIndex(3)
                }
            }
            .allowsHitTesting(false)

            // 素材和贴纸帧条只展示内容，不再叠加名称或类型图标。
            if showsNameOnTimeline(element) {
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
            }

            if isSelected {
                // 仿 iOS“照片”视频裁剪：只给当前展示范围画细黑框，未选区保持弱化。
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.black, lineWidth: 1.5)
                    .frame(width: max(metrics.activeWidth, 8), height: barHeight)
                    .offset(x: metrics.activeOffset)
                    .allowsHitTesting(false)

                // 两侧圆角拖拽柄略微超出胶片条，避免与缩略图融成一块。
                HStack(spacing: 0) {
                    Color.clear.frame(width: max(metrics.activeOffset - 2.5, 0))
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 5, height: barHeight + 8)
                    Spacer()
                        .frame(width: max(metrics.activeWidth - 5, 0))
                    Capsule()
                        .fill(Color.black)
                        .frame(width: 5, height: barHeight + 8)
                }
                // 必须左对齐：barWidth 是完整素材范围，不能把缩短后的有效区间居中。
                .frame(width: barWidth, height: barHeight, alignment: .leading)
                .allowsHitTesting(false)
            }

            if isLoopTrimDragging,
               let count = loopCount(element, metrics: metrics, spp: spp) {
                LoopCountBadge(count: count)
                    .offset(
                        x: min(
                            max(metrics.activeOffset + metrics.activeWidth - 52, 0),
                            max(barWidth - 52, 0)
                        ),
                        y: -(barHeight / 2 + 12)
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(width: barWidth, height: barHeight)
        .contentShape(Rectangle())
        // 与纵向 ScrollView 同时识别；手势内部只接受明确的横向拖动。
        .simultaneousGesture(elementDragGesture(element, spp: spp))
        .onTapGesture {
            appState.selectElement(element.id)
        }
    }

    /// 返回每个循环起点在素材条内的 x 坐标；只对素材和贴纸生效。
    private func loopBoundaryOffsets(
        _ element: CompositionElement,
        metrics: ElementTimelineMetrics,
        spp: CGFloat
    ) -> [CGFloat] {
        guard let cycleWidth = loopCycleWidth(element, spp: spp),
              cycleWidth > 2 else { return [] }
        var offsets: [CGFloat] = []
        var boundary = cycleWidth
        // activeWidth 可能包含两次以上循环，因此逐个绘制所有后续循环起点。
        while boundary < metrics.activeWidth - 1 {
            offsets.append(metrics.activeOffset + boundary)
            boundary += cycleWidth
        }
        return offsets
    }

    private func isLoopTrimActive(for id: UUID) -> Bool {
        guard let session = elementDragSession, session.id == id else { return false }
        if case .trimEnd = session.mode { return true }
        return false
    }

    private func loopCount(
        _ element: CompositionElement,
        metrics: ElementTimelineMetrics,
        spp: CGFloat
    ) -> Int? {
        guard let cycleWidth = loopCycleWidth(element, spp: spp),
              cycleWidth > 2 else { return nil }
        return max(1, Int(ceil(metrics.activeWidth / cycleWidth)))
    }

    /// 第一次循环的时间轴宽度；只对素材和贴纸生效。
    private func loopCycleWidth(_ element: CompositionElement, spp: CGFloat) -> CGFloat? {
        switch element.kind {
        case .clip(let clipID):
            guard let clip = FrameCache.shared.clip(id: clipID) else { return nil }
            let speed = max(clip.playbackSpeed, 0.01)
            let sourceDuration = max(clip.activeDuration, 0.001)
            let sourceStart = min(max(element.sourceStartTime, 0), sourceDuration)
            let sourceEnd = element.sourceEndTime.isFinite
                ? min(max(element.sourceEndTime, sourceStart), sourceDuration)
                : sourceDuration
            let activeDuration = max(element.endTime - element.startTime, 0.1)
            let sourceCycleDuration = max((sourceEnd - sourceStart) / speed, 0.1)
            let isLooping = activeDuration > sourceCycleDuration + 0.001
            let cycleDuration = isLooping ? max(sourceEnd / speed, 0.1) : sourceCycleDuration
            return max(cycleDuration / spp, 0)
        case .decoration(let decorationID):
            guard let duration = DecorationRenderer.stickerDefinition(for: decorationID)?.defaultDuration,
                  duration.isFinite, duration > 0 else { return nil }
            return duration / spp
        case .effect, .text:
            return nil
        }
    }

    /// 素材条内帧缩略图拼贴（按实际播放顺序平铺，最多 24 个）。
    /// 循环素材从第一次播放入点开始，回绕时从源区间起点继续，而不是每轮重启入点。
    private func thumbnails(
        for clip: SegmentedClip,
        element: CompositionElement,
        metrics: ElementTimelineMetrics,
        barWidth: CGFloat,
        spp: CGFloat
    ) -> some View {
        let thumbW: CGFloat = 26
        let count = max(Int(barWidth / thumbW), 1)
        let visibleCount = min(count, 24)
        let cellWidth = barWidth / CGFloat(visibleCount)
        let indices = (0..<visibleCount).map { i -> Int in
            let playbackFrames = clip.playbackFrameIndices
            guard !playbackFrames.isEmpty, clip.fps.isFinite, clip.fps > 0 else { return 0 }

            let speed = max(clip.playbackSpeed, 0.01)
            let sourceDuration = max(clip.activeDuration, 0.001)
            let sourceStart = min(max(element.sourceStartTime, 0), sourceDuration)
            let sourceEnd = element.sourceEndTime.isFinite
                ? min(max(element.sourceEndTime, sourceStart), sourceDuration)
                : sourceDuration
            let activeDuration = max(element.endTime - element.startTime, 0.1)
            let sourceCycleDuration = max((sourceEnd - sourceStart) / speed, 0.1)
            let isLooping = activeDuration > sourceCycleDuration + 0.001
            let rangeStart = isLooping ? 0 : sourceStart
            let startIndex = min(
                max(Int((rangeStart * clip.fps).rounded(.down)), 0),
                playbackFrames.count - 1
            )
            let endIndex = min(
                max(Int((sourceEnd * clip.fps).rounded(.up)), startIndex + 1),
                playbackFrames.count
            )
            let cycleFrameCount = max(endIndex - startIndex, 1)

            let x = (CGFloat(i) + 0.5) * cellWidth
            let sourceTime: TimeInterval
            if x < metrics.activeOffset {
                sourceTime = x * spp * speed
            } else {
                let elapsed = (x - metrics.activeOffset) * spp
                sourceTime = sourceStart + elapsed * speed
            }
            let relativeFrame = max(Int(((sourceTime - rangeStart) * clip.fps).rounded(.down)), 0)
            return playbackFrames[startIndex + (relativeFrame % cycleFrameCount)]
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
                        .stroke(isSelected ? Color.black : .clear, lineWidth: 1.5)
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
        // 纵向滑动交给轨道列表，只有明确横向拖动才移动音频。
        .simultaneousGesture(dragAudio(clip, spp: spp))
        .onTapGesture {
            appState.selectedAudioID = clip.id
            appState.clearElementSelection()
        }
    }

    // MARK: - 播放头（可拖动）

    private func playhead(spp: CGFloat, height: CGFloat, contentWidth: CGFloat) -> some View {
        let x = timelineLeadingInset + appState.currentTime / spp
        // 刻度尺与播放头共用时间内容的起始留白，0 秒保持同一中心线。
        let clampedX = min(max(x, timelineLeadingInset), contentWidth)
        let totalHeight = rulerHeight + height
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black)
                .frame(width: 1.5, height: totalHeight)
                .allowsHitTesting(false)
            TimelinePlayheadMarker()
                .fill(Color.black)
                .frame(width: 10, height: 7)
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
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.contentCoordinateSpace))
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
                appState.seek(to: max(value.location.x - timelineLeadingInset, 0) * spp)
            }
            .onEnded { _ in
                isScrubbing = false
                isTimelineManipulating = false
            }
    }

    // MARK: - 拖动（移动与裁剪分离手势）

    /// 一条素材只使用一个拖拽手势；按下时确定模式，整个手势期间不再重新命中。
    private func elementDragGesture(_ element: CompositionElement, spp: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.contentCoordinateSpace))
            .onChanged { value in
                if elementDragSession == nil {
                    // 上下滚动轨道时不建立素材编辑会话，也不锁住 ScrollView。
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard horizontal >= 8, horizontal > vertical * 1.5 else { return }
                    let metrics = elementMetrics(element, spp: spp)
                    // 手势坐标现在以整个时间轴内容为基准；换算回素材条内部坐标后再判断
                    // 左裁剪 / 整体移动 / 右裁剪的命中区域。
                    let localStartX = value.startLocation.x
                        - timelineLeadingInset
                        - metrics.outerStart
                    guard let mode = dragMode(at: localStartX, metrics: metrics) else { return }
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
                let didEdit = elementDragSession?.id == element.id
                elementDragSession = nil
                guard didEdit else { return }
                isTimelineManipulating = false
                appState.recomputeDuration()
                settleTimelineScaleDuration()
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

        // 已经超过一个源循环时，前端裁剪只改变时间轴起点，不能再用单次素材公式
        // 通过 anchor.end 反推 start，否则会瞬间跳到最后一个循环的起点并吃掉循环区间。
        let sourceCycleDuration = max((sourceEnd - anchor.sourceStart) / speed, 0.1)
        if anchor.end - anchor.start > sourceCycleDuration + 0.001 {
            let newStart = min(max(anchor.start + delta, 0), anchor.end - 0.1)
            let maximumSourceStart = max(sourceEnd - minimumSourceSpan, 0)
            let newSourceStart = min(
                max(anchor.sourceStart + (newStart - anchor.start) * speed, 0),
                maximumSourceStart
            )
            appState.updateElement(element.id, { element in
                element.startTime = newStart
                element.sourceStartTime = newSourceStart
                element.sourceEndTime = sourceEnd
            }, recomputeDuration: false)
            return
        }

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
        let requestedEnd = max(anchor.start + 0.1, anchor.end + delta)
        let firstCycleEnd = anchor.start + (oldSourceEnd - sourceStart) / speed
        let newSourceEnd: TimeInterval
        let newEnd: TimeInterval
        if requestedEnd <= firstCycleEnd {
            newSourceEnd = min(
                max(sourceStart + (requestedEnd - anchor.start) * speed, minimumSourceEnd),
                sourceDuration
            )
            newEnd = anchor.start + (newSourceEnd - sourceStart) / speed
        } else {
            // 超出当前源区间时保留源出点，时间轴多出的部分由渲染器循环播放。
            newSourceEnd = oldSourceEnd
            newEnd = requestedEnd
        }
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
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.contentCoordinateSpace))
            .onChanged { value in
                if audioDragAnchors[clip.id] == nil {
                    // 明确的上下手势留给轨道列表滚动，不移动音频。
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard horizontal >= 8, horizontal > vertical * 1.5 else { return }
                }
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
                let didEdit = audioDragAnchors.removeValue(forKey: clip.id) != nil
                guard didEdit else { return }
                isTimelineManipulating = false
                appState.finishAudioEdit()
                settleTimelineScaleDuration()
            }
    }

    private func elementSymbol(_ element: CompositionElement) -> String {
        switch element.kind {
        case .clip: "person.crop.rectangle"
        case .decoration: EditorTool.sticker.icon
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

    /// 素材保留类型图标；贴纸只显示帧条；二者都不显示名称。
    private func showsNameOnTimeline(_ element: CompositionElement) -> Bool {
        switch element.kind {
        case .clip, .decoration:
            return false
        case .effect, .text:
            return true
        }
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

/// 正常状态的循环接缝：很窄的明暗过渡，不切断缩略图画面。
private struct LoopBoundarySeam: View {
    let height: CGFloat

    var body: some View {
        LinearGradient(
            colors: [.clear, Color.black.opacity(0.16), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 4, height: max(height - 2, 1))
        .blur(radius: 0.35)
    }
}

/// 选中状态的循环起点：顶部边缘两侧相向的短圆弧，避免形成明显分割线。
private struct LoopBoundaryJoinArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY + 1
        let bottom = rect.maxY - 1
        let halfGap: CGFloat = 1
        let controlOffset: CGFloat = 5

        // 左侧弧线向左鼓出，右侧弧线向右鼓出，形成轻量的 )( 接缝。
        path.move(to: CGPoint(x: rect.midX - halfGap, y: top))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX - halfGap, y: bottom),
            control: CGPoint(x: rect.midX - controlOffset, y: rect.midY)
        )
        path.move(to: CGPoint(x: rect.midX + halfGap, y: top))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + halfGap, y: bottom),
            control: CGPoint(x: rect.midX + controlOffset, y: rect.midY)
        )
        return path
    }
}

/// 仅在拖动结束手柄时显示的循环次数提示，不占用时间轴常驻空间。
private struct LoopCountBadge: View {
    let count: Int

    var body: some View {
        Text("循环 ×\(count)")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Color.black.opacity(0.72), in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
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
