import LivingFrameCore
import SwiftUI
import UIKit

/// 时间轴（参考剪映/CapCut 与 iPhone 视频编辑器）：
/// - 左侧固定轨道标识，右侧为可横向/纵向滚动的多轨区域
/// - 顶部刻度尺，素材条使用缩略图胶片带和明显的选中态
/// - 播放头有较大的拖动热区，刻度尺支持直接拖动定位
/// - 双指捏合缩放时间刻度（1x~8x）
/// - 拖动整体移动（就近磁吸对齐），左右边缘手柄分别裁剪源入点/源出点
struct TimelineView: View {
    @EnvironmentObject private var appState: AppState
    /// 选中轨道后由外层展示属性检查器；时间轴本身不持有 sheet 状态。
    let onRequestInspector: () -> Void

    init(onRequestInspector: @escaping () -> Void = {}) {
        self.onRequestInspector = onRequestInspector
    }

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
    /// 右侧纵向滚动指示条不是素材内容的一部分，需保留独立呼吸区，避免和裁剪柄贴在一起。
    private let timelineScrollbarClearance: CGFloat = 14
    /// 视觉手柄保持纤细，但可触摸区域应接近 iOS 控件的舒适尺寸。
    private let trimHandleTouchWidth: CGFloat = 32
    private let trimHandleTouchHeight: CGFloat = 44
    /// 时间轴缩放（1x = 全时长铺满，8x = 放大到帧级）
    private let minimumZoom: CGFloat = 0.5
    @State private var zoom: CGFloat = 1
    @State private var lastPinchZoom: CGFloat = 1
    @State private var elementDragSession: ElementDragSession?
    @State private var didReachSourceBoundary = false
    @State private var layerReorderSession: LayerReorderSession?
    @State private var audioDragAnchors: [UUID: TimeInterval] = [:]
    @State private var playheadDragStart: TimeInterval?
    @State private var isScrubbing = false
    /// 直接操作时间内容时锁住横向 ScrollView，避免时间刻度随素材一起平移。
    @State private var isTimelineManipulating = false
    /// 拖拽期间冻结的刻度基准：操作中允许内容把它撑长，松手后再按实际内容收缩，
    /// 避免素材跟手移动时刻度反复重排。
    @State private var timelineScaleDuration: TimeInterval = 1
    /// 当前吸附参考线时间；只在拖动靠近目标时显示。
    @State private var timelineSnapTime: TimeInterval?
    /// 全部素材的对齐参考线。它只提供视觉提示，不改变“只吸附上下相邻轨道”的规则。
    @State private var timelineAlignmentTime: TimeInterval?
    /// 手势中的临时时间数据：只驱动时间轴自身，不在每个采样点发布整个工程。
    @State private var timelineElementPreviews: [UUID: ElementTiming] = [:]
    /// 放大时间轴后的横向浏览位置；与底部导航窗和原生横向滚动容器双向同步。
    @State private var timelineHorizontalOffset: CGFloat = 0
    /// 删除素材是不可直接恢复的破坏性操作，先经系统确认框确认。
    @State private var isShowingDeleteConfirmation = false

    private struct ElementDragAnchor {
        let start: TimeInterval
        let end: TimeInterval
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
        let sourceOffset: TimeInterval
        let playbackCount: Int
    }

    fileprivate struct ElementTimelineMetrics {
        let outerStart: CGFloat
        let barWidth: CGFloat
        let activeOffset: CGFloat
        let activeWidth: CGFloat
        let isLooping: Bool
    }

    private typealias TimelineSourceInfo = ElementPlaybackSource

    private struct ElementTiming {
        var start: TimeInterval
        var end: TimeInterval
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval
        var sourceOffset: TimeInterval
        var playbackCount: Int?

        init(
            start: TimeInterval,
            end: TimeInterval,
            sourceStart: TimeInterval,
            sourceEnd: TimeInterval,
            sourceOffset: TimeInterval = 0,
            playbackCount: Int? = nil
        ) {
            self.start = start
            self.end = end
            self.sourceStart = sourceStart
            self.sourceEnd = sourceEnd
            self.sourceOffset = sourceOffset
            self.playbackCount = playbackCount
        }

        init(_ element: CompositionElement) {
            start = element.startTime
            end = element.endTime
            sourceStart = element.sourceStartTime
            sourceEnd = element.sourceEndTime
            sourceOffset = element.sourcePlaybackOffset ?? 0
            playbackCount = element.playbackCount
        }
    }

    private enum ElementDragMode: Equatable {
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

    /// 时间轴裁剪调试日志。只在 Debug 构建输出，便于定位手势命中和四个时间字段
    /// 在“预览计算 → 松手提交”之间是否发生了变化。
    private func timelineDebug(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("xdz.timeline \(message())")
        #endif
    }

    private var rows: Int {
        guard let comp = appState.composition else { return 0 }
        return comp.elements.count + comp.audioClips.count
    }

    private var totalHeight: CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowSpacing
    }

    /// 时间轴从上到下直接对应画布从上层到下层；同层级按插入顺序稳定显示。
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

    /// 时间轴的比例尺使用工程时间线；素材行内部的源素材灰显区域另行计算。
    private func displayedTimelineDuration() -> TimeInterval {
        max(contentTimelineDuration(), timelineScaleDuration, 0.1)
    }

    /// 只根据工程中的 startTime/endTime 计算比例尺，不把 sourceStart/sourceEnd
    /// 或未播放的源素材尾部带入全局时间轴。
    private func contentTimelineDuration() -> TimeInterval {
        guard let comp = appState.composition else { return 0.1 }
        let fullContentEnd = comp.elements.map { max($0.startTime, $0.endTime) }.max() ?? 0
        return max(comp.duration, fullContentEnd, 0.1)
    }

    private func clipSourceRange(
        for element: CompositionElement,
        clip: SegmentedClip
    ) -> SourcePlaybackRange {
        let duration = clipSourceDuration(clip)
        return SourcePlaybackRange(
            duration: duration,
            start: element.sourceStartTime,
            end: element.sourceEndTime
        )
    }

    /// 旧工程可能保存了未设置的 sourceEndTime（Double.greatestFiniteMagnitude），
    /// 或素材元数据尚未完整恢复。时间轴裁剪必须使用真实的源素材时长。
    private func clipSourceDuration(_ clip: SegmentedClip) -> TimeInterval {
        clip.playbackSourceDuration
    }

    private func timelineClip(id: String) -> SegmentedClip? {
        if let cached = FrameCache.shared.clip(id: id) {
            return cached
        }
        if let clip = appState.clips.first(where: { $0.id == id }) {
            FrameCache.shared.registerInMemory(clip)
            timelineDebug(
                "clip.restoreFromAppState id=\(id.prefix(8)) " +
                "activeDuration=\(clip.activeDuration) duration=\(clip.duration)"
            )
            return clip
        }
        timelineDebug("clip.missing id=\(id.prefix(8))")
        return nil
    }

    private func timelineSourceInfo(for element: CompositionElement) -> TimelineSourceInfo? {
        appState.playbackSource(for: element)
    }

    private func timelineBackgroundMedia(id: String) -> BackgroundMediaItem? {
        appState.backgroundMedia.first(where: { $0.id == id })
            ?? BackgroundStore.shared.media(named: id)
    }

    private func timelineSourceRange(
        for element: CompositionElement,
        info: TimelineSourceInfo
    ) -> SourcePlaybackRange {
        SourcePlaybackRange(
            duration: info.duration,
            start: element.sourceStartTime,
            end: element.sourceEndTime
        )
    }

    private func timelineElementKind(_ element: CompositionElement) -> String {
        switch element.kind {
        case .clip(let clipID): return "clip:\(clipID.prefix(8))"
        case .background(let backgroundID): return "background:\(backgroundID)"
        case .decoration(let decorationID): return "decoration:\(decorationID)"
        case .effect(let effectID): return "effect:\(effectID)"
        case .text(let textID): return "text:\(textID)"
        case .canvasEdge: return "canvasEdge"
        @unknown default: return String(describing: element.kind)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            timelineHeader

            if let comp = appState.composition, !comp.elements.isEmpty || !comp.audioClips.isEmpty {
                GeometryReader { geo in
                    // 给左侧轨道标识预留固定宽度，时间内容从同一条左边线开始。
                    let viewportWidth = max(
                        geo.size.width - trackGutterWidth - 8 - timelineScrollbarClearance,
                        1
                    )
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
                    let maximumHorizontalOffset = max(contentWidth - viewportWidth, 0)
                    let showsHorizontalNavigator = zoom > 1.001 && maximumHorizontalOffset > 0.5
                    let navigatorHeight: CGFloat = showsHorizontalNavigator ? 38 : 0
                    // SwiftUI 的正交嵌套 ScrollView 会让内层吃掉单指 pan，用户只能
                    // 精确抓住右侧几 pt 的系统指示条。使用 UIKit 原生双容器后，外层
                    // 纵向滚动与内层横向滚动分别拥有各自的 pan 识别器，手指可直接从
                    // 时间轴内容开始浏览；轨道栏仍和纵向内容同步。
                    VStack(spacing: 0) {
                        TimelineScrollWorkspace(
                            gutterWidth: trackGutterWidth,
                            gutterSpacing: 8,
                            trailingScrollbarClearance: timelineScrollbarClearance,
                            contentSize: CGSize(width: contentWidth, height: contentHeight),
                            horizontalOffset: $timelineHorizontalOffset,
                            verticalScrollingEnabled: layerReorderSession == nil,
                            horizontalScrollingEnabled: !isTimelineManipulating,
                            gutter: AnyView(trackGutter(comp)),
                            timeContent: AnyView(
                                ZStack(alignment: .topLeading) {
                                ruler(width: viewportWidth, spp: spp)
                                    .frame(width: contentWidth, height: rulerHeight, alignment: .leading)

                                ForEach(Array(orderedElements.enumerated()), id: \.element.id) { i, element in
                                    let displayElement = elementWithTimelinePreview(element)
                                    elementRow(
                                        element,
                                        spp: spp,
                                        isLayerDropTarget: layerReorderSession?.currentIndex == i
                                    )
                                        .position(x: rowX(displayElement, spp: spp), y: rulerHeight + rowCenterY(i))
                                }

                                ForEach(Array(comp.audioClips.enumerated()), id: \.element.id) { i, audio in
                                    audioRow(audio, spp: spp)
                                        .position(x: audioX(audio, spp: spp), y: rulerHeight + rowCenterY(orderedElements.count + i))
                                }

                                layerReorderGuide(contentWidth: contentWidth)
                                playhead(spp: spp, height: totalHeight, contentWidth: contentWidth)
                                timelineSnapGuide(spp: spp, height: totalHeight, contentWidth: contentWidth)
                                }
                                .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                                .animation(
                                    .interactiveSpring(response: 0.28, dampingFraction: 0.82),
                                    value: orderedElements.map(\.id)
                                )
                                .coordinateSpace(name: Self.contentCoordinateSpace)
                            )
                        )
                        .simultaneousGesture(pinchZoomGesture)
                        .frame(
                            width: geo.size.width,
                            height: max(geo.size.height - navigatorHeight, 1),
                            alignment: .topLeading
                        )

                        if showsHorizontalNavigator {
                            TimelineHorizontalNavigator(
                                offset: $timelineHorizontalOffset,
                                maximumOffset: maximumHorizontalOffset,
                                viewportFraction: min(max(viewportWidth / contentWidth, 0.12), 1)
                            )
                            .padding(.leading, trackGutterWidth + 8)
                            .padding(.trailing, timelineScrollbarClearance)
                            .frame(height: navigatorHeight)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
            } else {
                timelineEmptyState
            }
        }
        .frame(maxHeight: .infinity)
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
        .alert(deleteConfirmationTitle, isPresented: $isShowingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                deleteSelectedTimelineItems()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    private func growTimelineScaleDurationIfNeeded() {
        let contentDuration = contentTimelineDuration()
        let nextDuration = max(timelineScaleDuration, contentDuration, 1)
        guard nextDuration > timelineScaleDuration + 0.001 else { return }
        timelineScaleDuration = nextDuration
        timelineDebug("scale.grow content=\(contentDuration) frozen=\(timelineScaleDuration)")
    }

    private func settleTimelineScaleDuration() {
        let contentDuration = contentTimelineDuration()
        timelineScaleDuration = max(contentDuration, 1)
        timelineDebug("scale.settle content=\(contentDuration) duration=\(appState.composition?.duration ?? -1) elements=\(appState.composition?.elements.count ?? 0)")
    }

    private var timelineHeader: some View {
        HStack(spacing: 8) {
            Label("时间轴", systemImage: "film.stack")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LF.textPrimary)

            if hasSelection {
                HStack(spacing: 6) {
                    Button(action: onRequestInspector) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(LF.accentGradient, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("调整当前选中素材")

                    Button {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(LF.destructive.opacity(0.9), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除当前选中素材")
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Button {
                    zoom = max(minimumZoom, zoom - 0.5)
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
                    .stroke(LF.header.opacity(0.12), lineWidth: 1)
            }

            Text(String(format: "%.2f / %.1f s", appState.currentTime, appState.composition?.duration ?? 0.0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.black)

            Button {
                appState.isReversed.toggle()
            } label: {
                Image(systemName: "arrow.right.arrow.left")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        appState.isReversed ? LF.selectionFill : Color.clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
                .foregroundStyle(appState.isReversed ? Color.black : LF.textSecondary)
            .accessibilityLabel("倒放")
        }
    }

    private var hasSelection: Bool {
        !appState.selectedElementIDs.isEmpty || appState.selectedAudioID != nil
    }

    private var deleteConfirmationTitle: String {
        if appState.selectedElementIDs.count > 1 {
            return "删除这 \(appState.selectedElementIDs.count) 个素材？"
        }
        if appState.selectedAudioID != nil {
            return "删除这段音频？"
        }
        return "删除这个素材？"
    }

    private var deleteConfirmationMessage: String {
        "删除后，素材将从画布和时间轴中移除。"
    }

    private func deleteSelectedTimelineItems() {
        // 先取快照；deleteElement 会同步更新选中集合，遍历原集合会漏删其余多选项。
        let selectedElementIDs = Array(appState.selectedElementIDs)
        let selectedAudioID = appState.selectedAudioID

        selectedElementIDs.forEach(appState.deleteElement)
        if let selectedAudioID {
            appState.deleteAudio(selectedAudioID)
        }
    }

    // MARK: - 缩放（双指捏合）

    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(max(lastPinchZoom * value.magnification, minimumZoom), 8)
            }
            .onEnded { _ in
                lastPinchZoom = zoom
            }
    }

    /// 空时间轴使用轻量的虚线引导框，避免提示文字孤零零地贴在左侧。
    private var timelineEmptyState: some View {
        VStack {
            Spacer(minLength: 0)

            Text("添加素材后显示时间轴")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LF.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 30)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            LF.brandTint.opacity(0.28),
                            style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                        )
                }
                .padding(.horizontal, 18)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .foregroundStyle(isDragging ? LF.selectionText : Color.black.opacity(0.78))
        .frame(width: 36, height: 30)
        .background(isDragging ? LF.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: 8))
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
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                UISelectionFeedbackGenerator().selectionChanged()
                session.currentIndex = targetIndex
                layerReorderSession = session
            }
            .onEnded { _ in
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
        guard let info = timelineSourceInfo(for: element) else {
            let activeDuration = max(element.endTime - element.startTime, 0.1)
            let activeWidth = max(activeDuration / spp, 20)
            return ElementTimelineMetrics(
                outerStart: element.startTime / spp,
                barWidth: activeWidth,
                activeOffset: 0,
                activeWidth: activeWidth,
                isLooping: false
            )
        }

        let speed = max(info.playbackRate, 0.01)
        let source = timelineSourceRange(for: element, info: info)
        let activeTimelineDuration = max(element.endTime - element.startTime, 0.1)
        let firstPlaybackOffset = min(max(element.sourcePlaybackOffset ?? 0, 0), source.span)
        let activeOffset = max((source.start + firstPlaybackOffset) / speed / spp, 0)
        let activeWidth = max(activeTimelineDuration / spp, 20)
        // 胶片带始终展示完整源素材；activeOffset/activeWidth 只表示实际播放区间。
        // 循环播放时，选区会变长，右侧未选区接在循环段之后，避免尾部原始帧消失。
        let activeSourceDistance = activeTimelineDuration * speed
        let rightInactiveWidth = max(
            (source.span - firstPlaybackOffset - activeSourceDistance) / speed / spp,
            0
        )
        let barWidth = max(activeOffset + activeWidth + rightInactiveWidth, 20)
        let isLooping = element.shouldLoop(cycleDuration: source.span / speed)
            || (max(element.sourcePlaybackOffset ?? 0, 0)
                + activeTimelineDuration * speed > source.span + 0.001)
        return ElementTimelineMetrics(
            outerStart: element.startTime / spp - activeOffset,
            barWidth: barWidth,
            activeOffset: activeOffset,
            activeWidth: activeWidth,
            isLooping: isLooping
        )
    }

    @ViewBuilder
    private func inactiveRangeOverlay(
        metrics: ElementTimelineMetrics,
        barWidth: CGFloat,
        barHeight: CGFloat,
        isSelected: Bool
    ) -> some View {
        let hasTrimmedFrames = metrics.activeOffset > 0.5 || metrics.activeWidth < barWidth - 0.5
        if hasTrimmedFrames {
            TimelineInactiveRangeMask(
                totalWidth: barWidth,
                leftWidth: metrics.activeOffset,
                rightWidth: barWidth - metrics.activeOffset - metrics.activeWidth,
                height: barHeight,
                opacity: isSelected ? 0.62 : 0.28
            )
            .frame(width: barWidth, height: barHeight)
            .zIndex(10)
        }
    }

    // MARK: - 元素行（帧缩略图拼贴）

    @ViewBuilder
    private func elementRow(
        _ element: CompositionElement,
        spp: CGFloat,
        isLayerDropTarget: Bool = false
    ) -> some View {
        let displayElement = elementWithTimelinePreview(element)
        let metrics = elementMetrics(displayElement, spp: spp)
        let barWidth = metrics.barWidth
        let barHeight = rowHeight - 8
        let isCanvasEdge: Bool = {
            if case .canvasEdge = element.kind { return true }
            return false
        }()
        let isLayerDragging = layerReorderSession?.id == element.id
        let layerFeedback = layerInteractionFeedback(
            isDragging: isLayerDragging,
            isDropTarget: isLayerDropTarget
        )
        let isSelected = appState.isElementSelected(element.id)
        let repeatCount = playbackCount(for: displayElement)
        let isTrimmingStart = isActiveTrim(element.id, mode: .trimStart)
        let isTrimmingEnd = isActiveTrim(element.id, mode: .trimEnd)
        let sourceInfo = timelineSourceInfo(for: displayElement)
        let sourceRange = sourceInfo.map {
            timelineSourceRange(for: displayElement, info: $0)
        }
        // 短素材时左右热区平分有效范围，避免两个透明手势区域互相覆盖。
        let handleHitWidth = min(trimHandleTouchWidth, max(metrics.activeWidth / 2, 10))
        let visualHandleWidth: CGFloat = 14
        let content = ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color(for: element).opacity(0.22))
                .frame(width: barWidth, height: barHeight)
            // 帧缩略图拼贴：人物素材和贴纸都在时间轴上显示实际帧。
            if case .clip(let clipID) = element.kind,
               let clip = timelineClip(id: clipID) {
                let fullStrip = thumbnails(
                    for: clip,
                    element: displayElement,
                    metrics: metrics,
                    barWidth: barWidth,
                    spp: spp
                )
                    .frame(width: barWidth, height: barHeight)
                    // 暗化直接附着在胶片条自身上，而不是作为外层 ZStack 的兄弟层。
                    // 这样在时间轴滚动容器重组、裁切时仍与帧图一同参与合成。
                    .overlay(alignment: .leading) {
                        inactiveRangeOverlay(
                            metrics: metrics,
                            barWidth: barWidth,
                            barHeight: barHeight,
                            isSelected: isSelected
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                // 只绘制一次完整帧带，避免同一帧被重复绘制后出现“选中区域也发灰”。
                fullStrip
                .allowsHitTesting(false)
            } else if case .decoration(let decorationID) = element.kind {
                StickerTimelineStrip(
                    decorationID: decorationID,
                    width: barWidth,
                    height: barHeight,
                    metrics: metrics,
                    secondsPerPoint: spp,
                    source: sourceRange,
                    playbackRate: sourceInfo?.playbackRate ?? 1,
                    playbackOffset: displayElement.sourcePlaybackOffset ?? 0
                )
                .frame(width: barWidth, height: barHeight, alignment: .leading)
                .overlay(alignment: .leading) {
                    inactiveRangeOverlay(
                        metrics: metrics,
                        barWidth: barWidth,
                        barHeight: barHeight,
                        isSelected: isSelected
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
            } else if case .background(let backgroundID) = element.kind,
                      let media = timelineBackgroundMedia(id: backgroundID) {
                BackgroundTimelineStrip(
                    media: media,
                    width: barWidth,
                    height: barHeight,
                    metrics: metrics,
                    secondsPerPoint: spp,
                    source: sourceRange,
                    playbackRate: sourceInfo?.playbackRate ?? 1,
                    playbackOffset: displayElement.sourcePlaybackOffset ?? 0
                )
                .frame(width: barWidth, height: barHeight, alignment: .leading)
                .overlay(alignment: .leading) {
                    inactiveRangeOverlay(
                        metrics: metrics,
                        barWidth: barWidth,
                        barHeight: barHeight,
                        isSelected: isSelected
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
            }

            if isCanvasEdge {
                HStack(spacing: 5) {
                    Image(systemName: elementSymbol(element))
                        .font(.system(size: 10, weight: .bold))
                    Text(displayName(for: element))
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("固定")
                        .font(.system(size: 8, weight: .medium))
                        .opacity(0.72)
                }
                .foregroundStyle(.white.opacity(0.96))
                .padding(.horizontal, 8)
                .frame(width: max(barWidth - 12, 0), height: barHeight, alignment: .leading)
                .allowsHitTesting(false)
            }

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
                // 当前有效播放范围使用视频编辑器常见的高对比选区框；选中帧保持原色，
                // 未选中的完整素材由两侧暗罩显示，用户可以清楚看到被裁掉的内容。
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(LF.selectionStroke, lineWidth: 3)
                    .frame(width: max(metrics.activeWidth, 8), height: barHeight)
                    .offset(x: metrics.activeOffset)
                    .shadow(color: LF.selectionText.opacity(0.30), radius: 3, y: 1)
                    .zIndex(20)
                    .allowsHitTesting(false)

                // 两侧圆角拖拽柄略微超出胶片条，避免与缩略图融成一块。
                // 所有可编辑元素都显示两侧手柄。
                // 动态元素沿用源素材/循环规则；静态元素只调整时间轴起点和时长。
                if !isCanvasEdge {
                HStack(spacing: 0) {
                    // 视觉手柄的中心必须和时间坐标边界重合。
                    Color.clear.frame(width: max(metrics.activeOffset - visualHandleWidth / 2, 0))
                    Capsule()
                        .fill(LF.selectionStroke)
                        .overlay {
                            HStack(spacing: 2) {
                                Capsule()
                                    .fill(LF.selectionText.opacity(isTrimmingStart ? 0.88 : 0.68))
                                    .frame(width: 2, height: 14)
                                Capsule()
                                    .fill(LF.selectionText.opacity(isTrimmingStart ? 0.88 : 0.68))
                                    .frame(width: 2, height: 14)
                            }
                        }
                        .frame(width: visualHandleWidth, height: barHeight + 10)
                        .shadow(
                            color: LF.selectionText.opacity(isTrimmingStart ? 0.42 : 0.26),
                            radius: isTrimmingStart ? 5 : 2
                        )
                    Spacer()
                        .frame(width: max(metrics.activeWidth - visualHandleWidth, 0))
                    Capsule()
                        .fill(LF.selectionStroke)
                        .overlay {
                            HStack(spacing: 2) {
                                Capsule()
                                    .fill(LF.selectionText.opacity(isTrimmingEnd ? 0.88 : 0.68))
                                    .frame(width: 2, height: 14)
                                Capsule()
                                    .fill(LF.selectionText.opacity(isTrimmingEnd ? 0.88 : 0.68))
                                    .frame(width: 2, height: 14)
                            }
                        }
                        .frame(width: visualHandleWidth, height: barHeight + 10)
                        .shadow(
                            color: LF.selectionText.opacity(isTrimmingEnd ? 0.42 : 0.26),
                            radius: isTrimmingEnd ? 5 : 2
                        )
                }
                // 必须左对齐：barWidth 是完整素材范围，不能把缩短后的有效区间居中。
                .frame(width: barWidth, height: barHeight, alignment: .leading)
                .allowsHitTesting(false)

                // 视觉手柄现在更容易辨认；这里仍保留每侧最多 32pt 的透明热区。
                // 该手势与纵向轨道滚动同时识别：只有真正横向移动时才会建立
                // 裁剪会话并锁住横向时间内容，竖向移动永远保留给轨道列表。
                Color.clear
                    .frame(width: handleHitWidth, height: trimHandleTouchHeight)
                    .contentShape(Rectangle())
                    .position(
                        // 与视觉手柄同心：热区同时覆盖边界内外，不能只落在素材条内部。
                        x: metrics.activeOffset,
                        y: barHeight / 2
                    )
                    // 手柄优先于素材条的整体移动手势，避免同一次拖拽被误判成右裁剪。
                    .highPriorityGesture(
                        elementDragGesture(element, spp: spp, fixedMode: .trimStart)
                    )

                Color.clear
                    .frame(width: handleHitWidth, height: trimHandleTouchHeight)
                    .contentShape(Rectangle())
                    .position(
                        // 右手柄同样以结束边界为中心。此前热区只在其左侧，用户按到
                        // 真实黑色手柄时会落到中部移动手势，因此感觉特别难拖。
                        x: metrics.activeOffset + metrics.activeWidth,
                        y: barHeight / 2
                    )
                    .highPriorityGesture(
                        elementDragGesture(element, spp: spp, fixedMode: .trimEnd)
                    )
                }
            }

            if repeatCount > 1 {
                if let sourceInfo {
                    let cycleDuration = sourceInfo.cycleDuration(for: displayElement)
                    let cycleWidth = cycleDuration / spp
                    // 太密时省略分隔线，避免细碎闪烁；不创建与帧数等量的视图。
                    if cycleWidth >= 6 {
                        let boundaryOffsets = TimelinePlaybackRules.loopBoundaryOffsets(
                            firstPlaybackOffset: displayElement.sourcePlaybackOffset ?? 0,
                            cycleDuration: cycleDuration,
                            playbackCount: repeatCount,
                            playbackRate: sourceInfo.playbackRate
                        )
                        ForEach(Array(boundaryOffsets.enumerated()), id: \.offset) { _, boundaryOffset in
                            Rectangle()
                                .fill(LF.selectionStroke.opacity(0.65))
                                .frame(width: 1, height: barHeight - 6)
                                .offset(x: metrics.activeOffset + boundaryOffset / spp)
                                .allowsHitTesting(false)
                        }
                    }
                }
                Button {
                    appState.selectElement(element.id)
                    onRequestInspector()
                } label: {
                    LoopCountBadge(count: repeatCount)
                }
                .buttonStyle(.plain)
                .offset(x: metrics.activeOffset + 6)
                .zIndex(21)
                .accessibilityLabel("播放 \(repeatCount) 次，编辑播放片段")
            }
        }
        .frame(width: barWidth, height: barHeight)
        .contentShape(Rectangle())

        if isCanvasEdge {
            content
                .onTapGesture { appState.selectElement(element.id) }
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        appState.selectElement(element.id)
                        onRequestInspector()
                    }
                )
                .overlay(layerFeedback)
                .scaleEffect(isLayerDragging ? 1.035 : 1)
        } else {
            content
                // 素材条中部只负责整体移动；两端由上面的专用热区负责裁剪。
                .simultaneousGesture(elementDragGesture(element, spp: spp, fixedMode: .move))
                .onTapGesture { appState.selectElement(element.id) }
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        appState.selectElement(element.id)
                        onRequestInspector()
                    }
                )
                .overlay(layerFeedback)
                .scaleEffect(isLayerDragging ? 1.035 : 1)
        }
    }

    private func layerInteractionFeedback(
        isDragging: Bool,
        isDropTarget: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isDragging ? LF.selectionFill.opacity(0.28) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isDragging ? LF.gold : (isDropTarget ? LF.selectionStroke : .clear),
                        style: StrokeStyle(
                            lineWidth: isDragging ? 2.5 : 2,
                            dash: isDropTarget && !isDragging ? [6, 4] : []
                        )
                    )
            }
            .shadow(
                color: isDragging ? LF.gold.opacity(0.32) : .clear,
                radius: isDragging ? 8 : 0,
                y: isDragging ? 3 : 0
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func layerReorderGuide(contentWidth: CGFloat) -> some View {
        if let session = layerReorderSession {
            let y = rulerHeight + CGFloat(session.currentIndex) * (rowHeight + rowSpacing) - 2
            HStack(spacing: 5) {
                Circle()
                    .fill(LF.gold)
                    .frame(width: 6, height: 6)
                Rectangle()
                    .fill(LF.gold)
                    .frame(height: 2)
                Circle()
                    .fill(LF.gold)
                    .frame(width: 6, height: 6)
            }
            .frame(width: max(contentWidth - timelineLeadingInset, 12), height: 8)
            .offset(x: timelineLeadingInset, y: y)
            .shadow(color: LF.gold.opacity(0.5), radius: 4)
            .allowsHitTesting(false)
            .zIndex(30)
        }
    }

    private func elementWithTimelinePreview(_ element: CompositionElement) -> CompositionElement {
        guard let preview = timelineElementPreviews[element.id] else { return element }
        var display = element
        display.startTime = preview.start
        display.endTime = preview.end
        display.sourceStartTime = preview.sourceStart
        display.sourceEndTime = preview.sourceEnd
        display.sourcePlaybackOffset = preview.sourceOffset
        if let playbackCount = preview.playbackCount {
            display.playbackCount = playbackCount
        }
        return display
    }

    /// 手指进入左右裁剪模式后立即强调对应手柄，让用户知道当前操控的是哪一端。
    private func isActiveTrim(_ id: UUID, mode: ElementDragMode) -> Bool {
        guard let session = elementDragSession, session.id == id else { return false }
        return session.mode == mode
    }

    private func playbackCount(for element: CompositionElement) -> Int {
        guard let source = timelineSourceInfo(for: element) else { return 1 }
        return element.resolvedPlaybackCount(cycleDuration: source.cycleDuration(for: element))
    }

    /// 素材条内帧缩略图拼贴（最多 24 个）。胶片带显示完整源素材，
    /// 播放范围通过遮罩强调；循环素材只在实际播放区间内回绕。
    @ViewBuilder
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
        let speed = max(clip.playbackSpeed, 0.01)
        let source = clipSourceRange(for: element, clip: clip)
        let playbackFrames = clip.playbackFrameIndices
        let indices = (0..<visibleCount).map { i -> Int in
            guard !playbackFrames.isEmpty, clip.fps.isFinite, clip.fps > 0 else { return 0 }

            let x = (CGFloat(i) + 0.5) * cellWidth
            let sourceTime = timelineSourceTimeForX(
                x,
                metrics: metrics,
                secondsPerPoint: spp,
                source: source,
                playbackRate: speed,
                playbackOffset: element.sourcePlaybackOffset ?? 0
            )
            let frameIndex = min(
                max(Int((sourceTime * clip.fps).rounded(.down)), 0),
                playbackFrames.count - 1
            )
            return playbackFrames[frameIndex]
        }
        HStack(spacing: 1) {
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
                        colors: [LF.timelineAudio.opacity(0.92), LF.brandTint.opacity(0.62)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: barWidth, height: rowHeight - 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? LF.header : .clear, lineWidth: 2)
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

    private func timelineSnapGuide(
        spp: CGFloat,
        height: CGFloat,
        contentWidth: CGFloat
    ) -> some View {
        Group {
            if let alignmentTime = timelineAlignmentTime,
               timelineSnapTime.map({ abs($0 - alignmentTime) > 0.001 }) ?? true {
                let x = min(
                    max(timelineLeadingInset + alignmentTime / spp, timelineLeadingInset),
                    contentWidth
                )
                Rectangle()
                    .fill(LF.gold.opacity(0.92))
                    .frame(width: 1, height: height + rulerHeight)
                    .overlay(alignment: .top) {
                        Text("对齐")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(LF.gold, in: Capsule())
                            .offset(y: -rulerHeight - 2)
                    }
                    .position(x: x, y: (height + rulerHeight) / 2)
                    .allowsHitTesting(false)
                    .zIndex(19)
            }
            if let snapTime = timelineSnapTime {
                let x = min(
                    max(timelineLeadingInset + snapTime / spp, timelineLeadingInset),
                    contentWidth
                )
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(LF.header.opacity(0.9))
                        .frame(width: 1.5, height: height + rulerHeight)
                    Text(String(format: "%.2fs", snapTime))
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                            .background(LF.header, in: Capsule())
                        .offset(y: -rulerHeight - 2)
                }
                .position(x: x, y: (height + rulerHeight) / 2)
                .allowsHitTesting(false)
                .zIndex(20)
            }
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

    /// 每个拖拽入口都有固定职责：中部移动、两端裁剪。这样在手势开始后不会在
    /// 移动/裁剪之间重新命中；只有横向意图成立时才接管时间内容。
    private func elementDragGesture(
        _ element: CompositionElement,
        spp: CGFloat,
        fixedMode: ElementDragMode
    ) -> some Gesture {
        // 先用很小的系统门槛接收手势，再在首次移动时判定方向；此前两个 8pt
        // 门槛叠加，会使裁剪手柄在真机上很难被拖起。
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.contentCoordinateSpace))
            .onChanged { value in
                if elementDragSession == nil {
                    // 上下滚动轨道时不建立素材编辑会话，也不锁住 ScrollView。
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard horizontal >= 4, horizontal > vertical * 1.2 else { return }
                    let metrics = elementMetrics(element, spp: spp)
                    // 中部拖拽入口忽略两端热区，防止外层 simultaneousGesture 与
                    // 专用裁剪热区同时建立不同的拖拽会话。
                    let localStartX = value.startLocation.x
                        - timelineLeadingInset
                        - metrics.outerStart
                    if fixedMode == .move,
                       isInsideTrimHotZone(localStartX, metrics: metrics) {
                        return
                    }
                    elementDragSession = ElementDragSession(
                        id: element.id,
                        mode: fixedMode,
                        anchor: ElementDragAnchor(
                            start: element.startTime,
                            end: element.endTime,
                            sourceStart: element.sourceStartTime,
                            sourceEnd: element.sourceEndTime,
                            sourceOffset: element.sourcePlaybackOffset ?? 0,
                            playbackCount: playbackCount(for: element)
                        ),
                        secondsPerPoint: spp
                    )
                    didReachSourceBoundary = false
                    timelineDebug(
                        "gesture.begin id=\(element.id.uuidString.prefix(8)) kind=\(timelineElementKind(element)) mode=\(fixedMode) " +
                        "start=\(element.startTime) end=\(element.endTime) " +
                        "sourceStart=\(element.sourceStartTime) sourceEnd=\(element.sourceEndTime) " +
                        "startX=\(value.startLocation.x) translationX=\(value.translation.width) " +
                        "spp=\(spp) outerStart=\(metrics.outerStart) activeOffset=\(metrics.activeOffset) activeWidth=\(metrics.activeWidth)"
                    )
                    // 即使素材原先未选中，直接拖动也应立刻呈现对应手柄反馈。
                    appState.selectElement(element.id)
                    if appState.isPlaying { appState.pause() }
                    appState.beginTimelineEdit()
                    isTimelineManipulating = true
                }

                // 外层整体移动手势与两侧裁剪手势可能同时收到同一触摸事件；
                // 一旦某个模式先建立会话，其他模式只能旁观，不能复用这次会话。
                guard let activeSession = elementDragSession,
                      activeSession.id == element.id,
                      activeSession.mode == fixedMode else { return }

                let session = activeSession
                let delta = value.translation.width * session.secondsPerPoint
                let timing: ElementTiming
                switch session.mode {
                case .move:
                    guard let comp = appState.composition else { return }
                    let duration = session.anchor.end - session.anchor.start
                    let newStart = snapMoveStart(
                        rawStart: max(session.anchor.start + delta, 0),
                        duration: duration,
                        excluding: element.id,
                        comp: comp,
                        secondsPerPoint: session.secondsPerPoint
                    )
                    timing = ElementTiming(
                        start: newStart,
                        end: newStart + duration,
                        sourceStart: session.anchor.sourceStart,
                        sourceEnd: session.anchor.sourceEnd,
                        sourceOffset: session.anchor.sourceOffset
                    )
                case .trimStart:
                    timing = trimmedStart(element, anchor: session.anchor, delta: delta, secondsPerPoint: session.secondsPerPoint)
                case .trimEnd:
                    timing = trimmedEnd(element, anchor: session.anchor, delta: delta, secondsPerPoint: session.secondsPerPoint)
                }
                if let source = timelineSourceInfo(for: element),
                   session.mode != .move,
                   session.anchor.playbackCount == 1 {
                    let atBoundary = session.mode == .trimEnd
                        ? timing.sourceEnd >= source.duration - 0.000001
                        : timing.sourceStart <= 0.000001
                    if atBoundary && !didReachSourceBoundary {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    didReachSourceBoundary = atBoundary
                }
                timelineElementPreviews[element.id] = timing
                timelineScaleDuration = max(timelineScaleDuration, timing.end, 1)
            }
            .onEnded { _ in
                let completedSession = elementDragSession
                let didEdit = completedSession?.id == element.id
                elementDragSession = nil
                guard didEdit else { return }
                timelineSnapTime = nil
                timelineAlignmentTime = nil
                isTimelineManipulating = false
                if let timing = timelineElementPreviews.removeValue(forKey: element.id) {
                    timelineDebug(
                        "commit.begin id=\(element.id.uuidString.prefix(8)) mode=\(completedSession?.mode as Any) " +
                        "timing.start=\(timing.start) timing.end=\(timing.end) " +
                        "timing.sourceStart=\(timing.sourceStart) timing.sourceEnd=\(timing.sourceEnd) " +
                        "timing.sourceOffset=\(timing.sourceOffset)"
                    )
                    let anchorCount = completedSession?.anchor.playbackCount ?? 1
                    let sourceInfo = timelineSourceInfo(for: element)
                    let cycleDuration = sourceInfo?.cycleDuration(for: element)
                    let phaseWraps = sourceInfo.map {
                        let sourceSpan = $0.range(for: element).span
                        return timing.sourceOffset + (timing.end - timing.start) * $0.playbackRate > sourceSpan + 0.0001
                    } ?? false
                    let becameLooping = completedSession?.mode != .move &&
                        (cycleDuration.map { timing.end - timing.start > $0 + 0.0001 } == true || phaseWraps)
                    let preserveLoop = anchorCount > 1 || becameLooping
                    let loopCount = preserveLoop
                        ? (timing.playbackCount ?? timelineLoopCount(
                            for: timing.end - timing.start,
                            element: element,
                            phase: timing.sourceOffset
                        ))
                        : nil
                    appState.updateElement(element.id, { element in
                        let before = ElementTiming(element)
                        guard let mode = completedSession?.mode else { return }
                        switch mode {
                        case .trimStart:
                            element.startTime = timing.start
                            element.endTime = timing.end
                            if let loopCount {
                                // 循环素材的源入点/出点由检查器维护；时间轴左手柄只改变
                                // 总时长，并据此确定循环次数。
                                element.playbackCount = loopCount
                                element.sourcePlaybackOffset = timing.sourceOffset
                            } else {
                                element.playbackCount = 1
                                element.sourcePlaybackOffset = timing.sourceOffset > 0.000001
                                    ? timing.sourceOffset
                                    : nil
                            }
                        case .trimEnd:
                            element.startTime = timing.start
                            element.endTime = timing.end
                            if let loopCount {
                                // 循环素材的右手柄只延长/缩短时间轴上的循环段，
                                // 不改变每一轮实际使用的源片段。
                                element.playbackCount = loopCount
                                element.sourcePlaybackOffset = timing.sourceOffset
                            } else {
                                element.playbackCount = 1
                                element.sourcePlaybackOffset = timing.sourceOffset > 0.000001
                                    ? timing.sourceOffset
                                    : nil
                            }
                        case .move:
                            // 整体移动只改变工程时间，不改变源素材入/出点。
                            element.startTime = timing.start
                            element.endTime = timing.end
                            element.sourcePlaybackOffset = timing.sourceOffset
                        }
                        timelineDebug(
                            "commit.applied id=\(element.id.uuidString.prefix(8)) mode=\(mode) " +
                            "before.start=\(before.start) before.end=\(before.end) " +
                            "before.sourceStart=\(before.sourceStart) before.sourceEnd=\(before.sourceEnd) " +
                            "after.start=\(element.startTime) after.end=\(element.endTime) " +
                            "after.sourceStart=\(element.sourceStartTime) after.sourceEnd=\(element.sourceEndTime) " +
                            "after.sourceOffset=\(element.sourcePlaybackOffset as Any) " +
                            "after.playbackCount=\(element.playbackCount as Any)"
                        )
                    }, recomputeDuration: false)
                }
                // 时间轴编辑只修改当前素材；不要把默认铺满的背景/贴纸重写到新的工程末尾。
                appState.recomputeDuration(autoFillOverlayElements: false)
                settleTimelineScaleDuration()
                appState.finishTimelineEdit()
            }
    }

    private func isInsideTrimHotZone(_ x: CGFloat, metrics: ElementTimelineMetrics) -> Bool {
        let width = min(trimHandleTouchWidth, max(metrics.activeWidth / 2, 10))
        let halfWidth = width / 2
        let leftRange = (metrics.activeOffset - halfWidth)...(metrics.activeOffset + halfWidth)
        let rightBoundary = metrics.activeOffset + metrics.activeWidth
        let rightRange = (rightBoundary - halfWidth)...(rightBoundary + halfWidth)
        return leftRange.contains(x) || rightRange.contains(x)
    }

    private func trimmedStart(
        _ element: CompositionElement,
        anchor: ElementDragAnchor,
        delta: CGFloat,
        secondsPerPoint: CGFloat
    ) -> ElementTiming {
        guard let info = timelineSourceInfo(for: element) else {
            timelineDebug(
                "trimStart.fallback id=\(element.id.uuidString.prefix(8)) " +
                "reason=noSourceRange kind=\(timelineElementKind(element))"
            )
            let staticTiming = TimelinePlaybackRules.trimStatic(
                TimelineStaticTiming(start: anchor.start, end: anchor.end),
                handle: .leading,
                delta: delta
            )
            let newStart = appState.composition.map {
                snapTime(
                    staticTiming.start,
                    excluding: element.id,
                    comp: $0,
                    secondsPerPoint: secondsPerPoint
                )
            } ?? staticTiming.start
            return ElementTiming(
                start: min(max(newStart, 0), anchor.end - 0.1),
                end: anchor.end,
                sourceStart: anchor.sourceStart,
                sourceEnd: anchor.sourceEnd,
                sourceOffset: anchor.sourceOffset
            )
        }

        let speed = max(info.playbackRate, 0.01)
        let result = TimelinePlaybackRules.trim(
            TimelinePlaybackState(
                sourceRange: timelineSourceRange(for: element, info: info),
                timelineStart: anchor.start,
                timelineEnd: anchor.end,
                firstPlaybackOffset: anchor.sourceOffset
            ),
            handle: .leading,
            delta: Double(delta),
            playbackRate: speed
        )
        let snappedStart = appState.composition.map {
            snapTime(
                result.state.timelineStart,
                excluding: element.id,
                comp: $0,
                secondsPerPoint: secondsPerPoint
            )
        } ?? result.state.timelineStart
        return ElementTiming(
            start: min(snappedStart, result.state.timelineEnd - 0.001),
            end: result.state.timelineEnd,
            sourceStart: anchor.sourceStart,
            sourceEnd: anchor.sourceEnd,
            sourceOffset: result.state.firstPlaybackOffset,
            playbackCount: result.playbackCount
        )
    }

    private func trimmedEnd(
        _ element: CompositionElement,
        anchor: ElementDragAnchor,
        delta: CGFloat,
        secondsPerPoint: CGFloat
    ) -> ElementTiming {
        guard let info = timelineSourceInfo(for: element) else {
            timelineDebug(
                "trimEnd.fallback id=\(element.id.uuidString.prefix(8)) " +
                "reason=noSourceRange kind=\(timelineElementKind(element))"
            )
            let staticTiming = TimelinePlaybackRules.trimStatic(
                TimelineStaticTiming(start: anchor.start, end: anchor.end),
                handle: .trailing,
                delta: delta
            )
            let newEnd = appState.composition.map {
                snapTime(
                    staticTiming.end,
                    excluding: element.id,
                    comp: $0,
                    secondsPerPoint: secondsPerPoint
                )
            } ?? staticTiming.end
            return ElementTiming(
                start: anchor.start,
                end: max(newEnd, anchor.start + 0.1),
                sourceStart: anchor.sourceStart,
                sourceEnd: anchor.sourceEnd,
                sourceOffset: anchor.sourceOffset
            )
        }

        let speed = max(info.playbackRate, 0.01)
        let result = TimelinePlaybackRules.trim(
            TimelinePlaybackState(
                sourceRange: timelineSourceRange(for: element, info: info),
                timelineStart: anchor.start,
                timelineEnd: anchor.end,
                firstPlaybackOffset: anchor.sourceOffset
            ),
            handle: .trailing,
            delta: Double(delta),
            playbackRate: speed
        )
        let snappedEnd = appState.composition.map {
            snapTime(
                result.state.timelineEnd,
                excluding: element.id,
                comp: $0,
                secondsPerPoint: secondsPerPoint
            )
        } ?? result.state.timelineEnd
        return ElementTiming(
            start: anchor.start,
            end: max(snappedEnd, anchor.start + 0.001),
            sourceStart: anchor.sourceStart,
            sourceEnd: anchor.sourceEnd,
            sourceOffset: result.state.firstPlaybackOffset,
            playbackCount: result.playbackCount
        )
    }

    private func normalizedLoopOffset(_ offset: TimeInterval, span: TimeInterval) -> TimeInterval {
        let safeSpan = max(span, 0.001)
        let remainder = offset.truncatingRemainder(dividingBy: safeSpan)
        return remainder >= 0 ? remainder : remainder + safeSpan
    }

    private func timelineLoopCount(
        for duration: TimeInterval,
        element: CompositionElement,
        phase: TimeInterval = 0
    ) -> Int {
        guard let source = timelineSourceInfo(for: element) else { return 1 }
        let cycleDuration = max(source.cycleDuration(for: element), 0.001)
        // playbackCount 负责打开循环渲染；实际播放长度仍由 startTime/endTime
        // 保留，所以最后一轮可以是不完整的一轮。
        let count = max(Int(ceil(max(duration, cycleDuration) / cycleDuration - 0.000001)), 1)
        let needsLooping = abs(normalizedLoopOffset(phase, span: source.range(for: element).span)) > 0.0001
        return min(max(needsLooping ? max(count, 2) : count, 1), 99)
    }

    /// 就近磁吸：参考其它视觉素材的开始/结束，不调整被参考素材。
    /// 吸附范围以“至少一帧、最多约 12 个屏幕点”为限，既容易命中又不会远距离跳动。
    private func snapTime(
        _ value: TimeInterval,
        excluding elementID: UUID,
        comp: Composition,
        secondsPerPoint: CGFloat
    ) -> TimeInterval {
        updateTimelineAlignmentGuide(
            for: [value],
            excluding: elementID,
            comp: comp,
            secondsPerPoint: secondsPerPoint
        )
        let points = trackSnapPoints(for: elementID, comp: comp)
        let threshold = snapThreshold(comp: comp, secondsPerPoint: secondsPerPoint)
        guard let nearest = points.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) <= threshold else {
            updateTimelineSnapGuide(nil)
            return value
        }
        updateTimelineSnapGuide(nearest)
        return nearest
    }

    private func snapMoveStart(
        rawStart: TimeInterval,
        duration: TimeInterval,
        excluding elementID: UUID,
        comp: Composition,
        secondsPerPoint: CGFloat
    ) -> TimeInterval {
        updateTimelineAlignmentGuide(
            for: [rawStart, rawStart + duration],
            excluding: elementID,
            comp: comp,
            secondsPerPoint: secondsPerPoint
        )
        let points = trackSnapPoints(for: elementID, comp: comp)
        let threshold = snapThreshold(comp: comp, secondsPerPoint: secondsPerPoint)
        var candidates: [(start: TimeInterval, guide: TimeInterval, distance: TimeInterval)] = []
        for point in points {
            candidates.append((point, point, abs(point - rawStart)))
            let endAlignedStart = point - duration
            if endAlignedStart >= 0 {
                candidates.append((endAlignedStart, point, abs(point - (rawStart + duration))))
            }
        }
        guard let nearest = candidates.min(by: { $0.distance < $1.distance }),
              nearest.distance <= threshold else {
            updateTimelineSnapGuide(nil)
            return rawStart
        }
        updateTimelineSnapGuide(nearest.guide)
        return nearest.start
    }

    private func trackSnapPoints(for elementID: UUID, comp: Composition) -> [TimeInterval] {
        comp.elements
            .filter { $0.id != elementID }
            .flatMap { [$0.startTime, $0.endTime] }
            .filter { $0.isFinite && $0 >= 0 }
    }

    private func snapThreshold(comp: Composition, secondsPerPoint: CGFloat) -> TimeInterval {
        let frame = 1 / max(comp.fps, 1)
        let visibleDistance = TimeInterval(max(secondsPerPoint, 0.0001) * 12)
        return max(frame + 0.0005, min(0.12, visibleDistance))
    }

    /// 所有其它素材都参与“看得见的对齐”，但不参与实际磁吸。
    private func updateTimelineAlignmentGuide(
        for movingEdges: [TimeInterval],
        excluding elementID: UUID,
        comp: Composition,
        secondsPerPoint: CGFloat
    ) {
        let points = comp.elements
            .filter { $0.id != elementID }
            .flatMap { [$0.startTime, $0.endTime] }
            .filter { $0.isFinite && $0 >= 0 }
        let threshold = max(0.06, min(0.18, TimeInterval(secondsPerPoint * 14)))
        let candidates = movingEdges.flatMap { edge in
            points.map { point in (time: point, distance: abs(point - edge)) }
        }
        guard let nearest = candidates.min(by: { $0.distance < $1.distance }),
              nearest.distance <= threshold else {
            timelineAlignmentTime = nil
            return
        }
        timelineAlignmentTime = nearest.time
    }

    private func updateTimelineSnapGuide(_ time: TimeInterval?) {
        if let time,
           timelineSnapTime == nil || abs((timelineSnapTime ?? time) - time) > 0.001 {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        timelineSnapTime = time
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
                    appState.beginTimelineEdit()
                    isTimelineManipulating = true
                    return clip.startTime
                }()
                let delta = value.translation.width * spp
                let rawStart = min(max(anchor + delta, 0), max(0, comp.duration - clip.duration))
                appState.updateAudio(clip.id, { clip in
                    // 音频不参与元素轨道的上下邻接吸附，避免拖动时突然贴到无关画面素材。
                    clip.startTime = rawStart
                }, syncPreview: false)
            }
            .onEnded { _ in
                let didEdit = audioDragAnchors.removeValue(forKey: clip.id) != nil
                guard didEdit else { return }
                timelineSnapTime = nil
                timelineAlignmentTime = nil
                isTimelineManipulating = false
                appState.finishAudioEdit()
                settleTimelineScaleDuration()
                appState.finishTimelineEdit()
            }
    }

    private func elementSymbol(_ element: CompositionElement) -> String {
        switch element.kind {
        case .clip: "person.crop.rectangle"
        case .background: "photo.on.rectangle"
        case .decoration: EditorTool.sticker.icon
        case .effect: "sparkles"
        case .text: "textformat"
        case .canvasEdge: "rectangle.inset.filled"
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
        case .clip, .background, .decoration:
            return false
        case .effect, .text:
            return true
        case .canvasEdge:
            return false
        }
    }

    private func color(for element: CompositionElement) -> Color {
        switch element.kind {
        case .clip: LF.timelineClip.opacity(0.82)
        case .background: LF.timelineBackground.opacity(0.82)
        case .decoration: LF.timelineSticker.opacity(0.82)
        case .effect: LF.timelineEffect.opacity(0.75)
        // 文字轨道使用独立语义色，不跟随文字本身的白/黑/彩色设置，
        // 避免浅色主题下出现黑灰色底配白字的低质感组合。
        case .text: LF.timelineText.opacity(0.90)
        case .canvasEdge: LF.header.opacity(0.9)
        }
    }
}

/// 原生正交滚动工作区：外层只负责轨道的纵向浏览，右侧内层只负责时间的横向浏览。
/// 这比 SwiftUI 的两个嵌套 ScrollView 更接近剪辑软件的手势模型：用户无需抓住
/// 细小的系统滚动条，直接在内容上滑即可；系统仍提供惯性、回弹和位置指示。
private struct TimelineScrollWorkspace: UIViewRepresentable {
    let gutterWidth: CGFloat
    let gutterSpacing: CGFloat
    let trailingScrollbarClearance: CGFloat
    let contentSize: CGSize
    @Binding var horizontalOffset: CGFloat
    let verticalScrollingEnabled: Bool
    let horizontalScrollingEnabled: Bool
    let gutter: AnyView
    let timeContent: AnyView

    func makeUIView(context: Context) -> TimelineScrollWorkspaceView {
        let view = TimelineScrollWorkspaceView()
        view.horizontalScrollView.delegate = context.coordinator
        view.apply(
            gutterWidth: gutterWidth,
            gutterSpacing: gutterSpacing,
            trailingScrollbarClearance: trailingScrollbarClearance,
            contentSize: contentSize,
            requestedHorizontalOffset: horizontalOffset,
            verticalScrollingEnabled: verticalScrollingEnabled,
            horizontalScrollingEnabled: horizontalScrollingEnabled,
            gutter: gutter,
            timeContent: timeContent
        )
        return view
    }

    func updateUIView(_ view: TimelineScrollWorkspaceView, context: Context) {
        context.coordinator.horizontalOffset = $horizontalOffset
        view.apply(
            gutterWidth: gutterWidth,
            gutterSpacing: gutterSpacing,
            trailingScrollbarClearance: trailingScrollbarClearance,
            contentSize: contentSize,
            requestedHorizontalOffset: horizontalOffset,
            verticalScrollingEnabled: verticalScrollingEnabled,
            horizontalScrollingEnabled: horizontalScrollingEnabled,
            gutter: gutter,
            timeContent: timeContent
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(horizontalOffset: $horizontalOffset)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var horizontalOffset: Binding<CGFloat>

        init(horizontalOffset: Binding<CGFloat>) {
            self.horizontalOffset = horizontalOffset
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !scrollView.isTracking || abs(horizontalOffset.wrappedValue - scrollView.contentOffset.x) > 0.5 else {
                return
            }
            horizontalOffset.wrappedValue = scrollView.contentOffset.x
        }
    }
}

private final class TimelineScrollWorkspaceView: UIView {
    private let verticalScrollView = UIScrollView()
    let horizontalScrollView = UIScrollView()
    private let gutterHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let timeHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var gutterWidth: CGFloat = 0
    private var gutterSpacing: CGFloat = 0
    private var trailingScrollbarClearance: CGFloat = 0
    private var timelineContentSize: CGSize = .zero
    private var requestedHorizontalOffset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        clipsToBounds = true

        verticalScrollView.backgroundColor = .clear
        verticalScrollView.alwaysBounceVertical = true
        verticalScrollView.showsVerticalScrollIndicator = true
        verticalScrollView.showsHorizontalScrollIndicator = false
        verticalScrollView.isDirectionalLockEnabled = true
        verticalScrollView.delaysContentTouches = false

        horizontalScrollView.backgroundColor = .clear
        horizontalScrollView.alwaysBounceHorizontal = true
        horizontalScrollView.showsHorizontalScrollIndicator = true
        horizontalScrollView.showsVerticalScrollIndicator = false
        horizontalScrollView.isDirectionalLockEnabled = true
        horizontalScrollView.delaysContentTouches = false

        gutterHost.view.backgroundColor = .clear
        timeHost.view.backgroundColor = .clear
        verticalScrollView.addSubview(gutterHost.view)
        verticalScrollView.addSubview(horizontalScrollView)
        horizontalScrollView.addSubview(timeHost.view)
        addSubview(verticalScrollView)

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        gutterWidth: CGFloat,
        gutterSpacing: CGFloat,
        trailingScrollbarClearance: CGFloat,
        contentSize: CGSize,
        requestedHorizontalOffset: CGFloat,
        verticalScrollingEnabled: Bool,
        horizontalScrollingEnabled: Bool,
        gutter: AnyView,
        timeContent: AnyView
    ) {
        self.gutterWidth = gutterWidth
        self.gutterSpacing = gutterSpacing
        self.trailingScrollbarClearance = trailingScrollbarClearance
        timelineContentSize = contentSize
        self.requestedHorizontalOffset = requestedHorizontalOffset
        verticalScrollView.isScrollEnabled = verticalScrollingEnabled
        horizontalScrollView.isScrollEnabled = horizontalScrollingEnabled
        gutterHost.rootView = gutter
        timeHost.rootView = timeContent
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        verticalScrollView.frame = bounds
        verticalScrollView.contentSize = CGSize(width: bounds.width, height: timelineContentSize.height)

        gutterHost.view.frame = CGRect(
            x: 0,
            y: 0,
            width: gutterWidth,
            height: timelineContentSize.height
        )

        let horizontalOrigin = gutterWidth + gutterSpacing
        horizontalScrollView.frame = CGRect(
            x: horizontalOrigin,
            y: 0,
            width: max(bounds.width - horizontalOrigin - trailingScrollbarClearance, 1),
            height: timelineContentSize.height
        )
        horizontalScrollView.contentSize = timelineContentSize
        timeHost.view.frame = CGRect(origin: .zero, size: timelineContentSize)

        let maximumOffset = max(timelineContentSize.width - horizontalScrollView.bounds.width, 0)
        let targetOffset = min(max(requestedHorizontalOffset, 0), maximumOffset)
        if !horizontalScrollView.isTracking,
           !horizontalScrollView.isDecelerating,
           abs(horizontalScrollView.contentOffset.x - targetOffset) > 0.5 {
            horizontalScrollView.contentOffset.x = targetOffset
        }
    }

}

/// 放大后的时间轴导航窗。它是横向浏览的明确入口，不与素材本身的移动/裁剪手势竞争。
private struct TimelineHorizontalNavigator: View {
    @Binding var offset: CGFloat
    let maximumOffset: CGFloat
    let viewportFraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            let trackWidth = max(geo.size.width, 1)
            let thumbWidth = min(max(trackWidth * viewportFraction, 42), trackWidth)
            let usableWidth = max(trackWidth - thumbWidth, 1)
            let progress = maximumOffset > 0 ? min(max(offset / maximumOffset, 0), 1) : 0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.07))
                    .overlay {
                        HStack(spacing: 3) {
                            ForEach(0..<8, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(index.isMultiple(of: 2) ? LF.header.opacity(0.22) : LF.gold.opacity(0.22))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, index.isMultiple(of: 3) ? 4 : 7)
                            }
                        }
                        .padding(.horizontal, 5)
                    }

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LF.header.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(LF.header, lineWidth: 1.5)
                    }
                    .frame(width: thumbWidth, height: 24)
                    .offset(x: progress * usableWidth)
                    .shadow(color: LF.header.opacity(0.18), radius: 3, y: 1)
            }
            .frame(height: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let position = min(
                            max(value.location.x - thumbWidth / 2, 0),
                            usableWidth
                        )
                        offset = maximumOffset * position / usableWidth
                    }
            )
            .accessibilityLabel("横向浏览时间轴")
            .accessibilityValue("当前位置 \(Int(progress * 100))%")
        }
    }
}

/// 胶片条的通用源时间映射。它必须和 TimelineView 的裁剪计算使用同一套边界，
/// 否则视觉上的高亮区会与实际播放区间错位。
private func timelineSourceTimeForX(
    _ x: CGFloat,
    metrics: TimelineView.ElementTimelineMetrics,
    secondsPerPoint: CGFloat,
    source: SourcePlaybackRange,
    playbackRate: TimeInterval,
    playbackOffset: TimeInterval = 0
) -> TimeInterval {
    let rate = max(playbackRate, 0.01)
    let activeEnd = metrics.activeOffset + metrics.activeWidth
    if x < metrics.activeOffset {
        let elapsed = max(x * secondsPerPoint * rate, 0)
        return min(max(source.start + elapsed, 0), source.duration)
    }
    if x < activeEnd {
        let elapsed = max((x - metrics.activeOffset) * secondsPerPoint * rate, 0)
        return source.sourceTime(
            at: elapsed / rate,
            playbackRate: rate,
            phase: playbackOffset,
            looping: metrics.isLooping
        )
    }
    let elapsed = max((x - activeEnd) * secondsPerPoint * rate, 0)
    let activeSourceOffset = min(
        max(metrics.activeOffset * secondsPerPoint * rate - source.start, 0)
            + metrics.activeWidth * secondsPerPoint * rate,
        source.span
    )
    return min(max(source.start + activeSourceOffset + elapsed, 0), source.duration)
}

private struct BackgroundTimelineStrip: View {
    let media: BackgroundMediaItem
    let width: CGFloat
    let height: CGFloat
    let metrics: TimelineView.ElementTimelineMetrics
    let secondsPerPoint: CGFloat
    let source: SourcePlaybackRange?
    let playbackRate: TimeInterval
    let playbackOffset: TimeInterval
    @State private var frames: [CGImage] = []

    var body: some View {
        Group {
            if frames.isEmpty {
                Color.black.opacity(0.15)
            } else {
                HStack(spacing: 1) {
                    ForEach(0..<cellCount, id: \.self) { index in
                        let frameIndex = mappedFrameIndex(at: index)
                        Image(decorative: frames[frameIndex], scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: cellWidth, height: height)
                            .clipped()
                    }
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .task(id: previewTaskID) {
            let id = media.id
            let count = cellCount
            let duration = max(media.duration, 0.1)
            let isAnimated = media.isAnimated
            let loaded = await Task.detached(priority: .utility) {
                let sampleCount = isAnimated ? count : 1
                return (0..<sampleCount).compactMap { index in
                    let time = duration * Double(index) / Double(max(sampleCount - 1, 1))
                    return BackgroundStore.shared.loadFrame(named: id, at: time)
                }
            }.value
            guard !Task.isCancelled else { return }
            frames = loaded
        }
    }

    private var cellCount: Int {
        max(min(Int(width / 28), 24), 1)
    }

    private var cellWidth: CGFloat {
        max((width - CGFloat(max(cellCount - 1, 0))) / CGFloat(cellCount), 0)
    }

    private var previewTaskID: String {
        "\(media.id)-\(cellCount)"
    }

    private func mappedFrameIndex(at index: Int) -> Int {
        guard frames.count > 1, let source else {
            return min(index, max(frames.count - 1, 0))
        }
        let x = (CGFloat(index) + 0.5) * cellWidth
        let sourceTime = timelineSourceTimeForX(
            x,
            metrics: metrics,
            secondsPerPoint: secondsPerPoint,
            source: source,
            playbackRate: playbackRate,
            playbackOffset: playbackOffset
        )
        let progress = source.duration > 0 ? sourceTime / source.duration : 0
        return min(max(Int((progress * CGFloat(frames.count - 1)).rounded()), 0), frames.count - 1)
    }
}

/// 常驻总播放次数，明确区分重复片段与普通裁剪片段。
private struct LoopCountBadge: View {
    let count: Int

    var body: some View {
        Text("↻ ×\(count)")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(LF.selectionText)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(LF.selectionFill, in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
    }
}

/// 贴纸时间轴帧条：异步读取已缓存的贴纸帧，并沿时间轴平铺显示。
private struct StickerTimelineStrip: View {
    let decorationID: String
    let width: CGFloat
    let height: CGFloat
    let metrics: TimelineView.ElementTimelineMetrics
    let secondsPerPoint: CGFloat
    let source: SourcePlaybackRange?
    let playbackRate: TimeInterval
    let playbackOffset: TimeInterval

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
                        let frameIndex = mappedFrameIndex(at: index)
                        Image(decorative: frames[frameIndex], scale: 1)
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

    private func mappedFrameIndex(at index: Int) -> Int {
        guard frames.count > 1, let source else {
            return min(index, max(frames.count - 1, 0))
        }
        let cellWidth = width / CGFloat(cellCount)
        let x = (CGFloat(index) + 0.5) * cellWidth
        let sourceTime = timelineSourceTimeForX(
            x,
            metrics: metrics,
            secondsPerPoint: secondsPerPoint,
            source: source,
            playbackRate: playbackRate,
            playbackOffset: playbackOffset
        )
        let frameDuration = source.duration / CGFloat(frames.count)
        return min(max(Int((sourceTime / max(frameDuration, 0.001)).rounded(.down)), 0), frames.count - 1)
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
