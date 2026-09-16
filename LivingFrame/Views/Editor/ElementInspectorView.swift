import LivingFrameCore
import SwiftUI
import UIKit

/// 检查器：按选中类型分派（视频元素 / 音频段）
struct ElementInspectorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // 直接使用 popover 的主题背景，不再套一层大卡片，避免与 NavigationBar
        // 和内部控制卡片叠出多重白色/渐变层。
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                if appState.selectedBackground {
                    backgroundInspector
                } else if let id = appState.primarySelectedID,
                          let element = appState.composition?.elements.first(where: { $0.id == id }) {
                    elementInspector(element)
                } else if appState.selectedElementIDs.count > 1 {
                    multiSelectionSummary
                } else if let id = appState.selectedAudioID,
                          let clip = appState.composition?.audioClips.first(where: { $0.id == id }) {
                    audioInspector(clip)
                } else {
                    Text("点击画布或时间轴上的元素进行编辑")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
        .background(LF.background)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - 背景检查器

    private var backgroundInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            backgroundInspectorHeader
            canvasAppearanceEditor
        }
    }

    private var canvasAppearanceEditor: some View {
        let composition = appState.composition
        let background = composition?.background
        return CanvasAppearanceEditor(
            aspect: CanvasAspect.aspect(for: composition?.canvasRect.size ?? CanvasAspect.portrait9x16.canvasSize),
            backgroundIsTransparent: background?.kind == .clear,
            backgroundIsSolid: background?.kind == .solid,
            backgroundHex: background?.topColor ?? "FFFFFF",
            edgeStyle: composition?.canvasEdgeStyle ?? .none,
            pattern: background?.patternOverlay,
            onSelectAspect: appState.setCanvasAspect,
            onSelectTransparent: appState.setTransparentBackground,
            onSelectColor: { appState.setBackground(color: $0) },
            onSelectEdgeStyle: appState.setCanvasEdgeStyle,
            onSelectPattern: appState.setBackgroundPattern
        )
    }

    /// 多选时：数量 + 批量操作
    private var multiSelectionSummary: some View {
        VStack(spacing: 10) {
            HStack {
                Text("已选中 \(appState.selectedElementIDs.count) 个素材")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(role: .destructive) {
                    let ids = appState.selectedElementIDs
                    for id in ids {
                        appState.deleteElement(id)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            Text("画布上拖动可一起移动，双指缩放/旋转作用于全部选中素材")
                .font(.caption)
                .foregroundStyle(LF.textSecondary)
        }
    }

    // MARK: - 视频元素

    private func elementInspector(_ element: CompositionElement) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: elementInspectorIcon(for: element))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.selectionText)
                    .frame(width: 36, height: 36)
                    .background(LF.surface2.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(LF.brandTint.opacity(0.14), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(inspectorElementName(for: element))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(LF.textPrimary)
                        .lineLimit(1)
                    Text("当前元素")
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                }

                Spacer()
                HStack(spacing: 4) {
                    inspectorActionButton(
                        systemName: "square.3.layers.3d.down.right",
                        accessibilityLabel: "下移图层"
                    ) {
                        appState.moveElementZ(element.id, up: false)
                    }
                    inspectorActionButton(
                        systemName: "square.3.layers.3d.up.right",
                        accessibilityLabel: "上移图层"
                    ) {
                        appState.moveElementZ(element.id, up: true)
                    }
                    Button(role: .destructive) { appState.deleteElement(element.id) } label: {
                        Image(systemName: "trash")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(LF.brandTint.opacity(0.14), lineWidth: 1)
            }

            if let source = appState.playbackSource(for: element) {
                ElementPlaybackControls(element: element, source: source)
            }

            if case .canvasEdge = element.kind {
                canvasEdgeElementInspector
            } else if case .background = element.kind {
                backgroundElementInspector(element)
            } else {
                if case .clip(let clipID) = element.kind,
                   let clip = appState.clips.first(where: { $0.id == clipID }) {
                    stickerStylePicker(clip, element: element)
                    if appState.playbackSource(for: element) != nil {
                        speedPicker(clip)
                    }
                }
                if case .text(let textID) = element.kind,
                   let text = appState.composition?.texts.first(where: { $0.id.uuidString == textID }) {
                    textEditor(text)
                } else {
                    filterPicker(element)
                    elementBackgroundPicker(element)
                }
            }
        }
    }

    private func inspectorActionButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(LF.surface2.opacity(0.68), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(LF.brandTint.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(LF.textSecondary)
        .accessibilityLabel(accessibilityLabel)
    }

    private func inspectorElementName(for element: CompositionElement) -> String {
        guard case .background = element.kind,
              element.collageGroupID == nil else {
            return element.name
        }

        // 兼容早期普通入口误用“拼接素材”默认名称的工程；不改写工程数据，
        // 仅在检查器展示时按当前独立相册元素的语义显示。
        let legacyCollageName = NSLocalizedString("拼接素材", comment: "Collage element")
        if element.name == "拼接素材" || element.name == legacyCollageName {
            return NSLocalizedString("照片", comment: "Standalone album element")
        }
        return element.name
    }

    private func elementInspectorIcon(for element: CompositionElement) -> String {
        switch element.kind {
        case .clip: return "film"
        case .background: return "photo.on.rectangle"
        case .decoration: return "face.smiling"
        case .effect: return "sparkles"
        case .text: return EditorTool.textIcon
        case .canvasEdge: return "square"
        @unknown default: return "square"
        }
    }

    private var canvasEdgeElementInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("画布边框是透明图层，可在时间轴左侧长按拖动调整层级")
                .font(.caption)
                .foregroundStyle(LF.textSecondary)
            inspectorChoiceRow(
                title: "样式",
                items: CanvasEdgeStyle.allCases,
                selected: appState.composition?.canvasEdgeStyle ?? .none
            ) { style in
                appState.setCanvasEdgeStyle(style)
            }
        }
    }

    private func backgroundElementInspector(_ element: CompositionElement) -> some View {
        let settings = element.backgroundSettings ?? BackgroundElementSettings()
        let isCollageElement = element.collageGroupID != nil
        return VStack(alignment: .leading, spacing: 10) {
            if let comp = appState.composition,
               case .background(let backgroundID) = element.kind,
               let frame = BackgroundStore.shared.loadFrame(named: backgroundID, at: appState.currentTime) {
                BackgroundEditingPreview(
                    items: [BackgroundEditingPreviewItem(
                        id: element.id,
                        frame: frame,
                        settings: settings,
                        zIndex: element.zIndex
                    )],
                    layoutSettings: settings,
                    activeElementSettings: settings,
                    focusedPartition: nil,
                    canvasAspect: comp.canvasRect.width / comp.canvasRect.height,
                    canvasSize: comp.canvasRect.size,
                    activeElementID: element.id,
                    isDividerLayoutLocked: settings.isDividerLayoutLocked,
                    onElementTap: { _, partition in
                        appState.toggleBackgroundPartition(element.id, partition)
                    },
                    onPartitionTap: { partition in
                        appState.toggleBackgroundPartition(element.id, partition)
                    },
                    onDividerOffsetChange: { dividerIndex, offset in
                        appState.setBackgroundDividerOffset(
                            element.id,
                            dividerIndex: dividerIndex,
                            offset: offset
                        )
                    },
                    onDividerPivotChange: { dividerIndex, pivot in
                        appState.setBackgroundDividerPivot(
                            element.id,
                            dividerIndex: dividerIndex,
                            pivot
                        )
                    },
                    onCropScaleChange: { scale in
                        appState.setBackgroundCropScale(element.id, scale)
                    },
                    onCropOffsetChange: { offset in
                        appState.setBackgroundCropOffset(element.id, offset)
                    }
                )
            }

            if isCollageElement {
                BackgroundDividerControls(
                    settings: settings,
                    canvasRect: appState.composition?.canvasRect
                        ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                    isDividerLayoutLocked: backgroundDividerLayoutLockBinding(for: element.id),
                    onAddDivider: {
                        appState.addBackgroundDividerLine(element.id)
                    },
                    onRemoveDivider: { dividerIndex in
                        appState.removeBackgroundDividerLine(element.id, dividerIndex: dividerIndex)
                    },
                    onAngleChange: { dividerIndex, angle in
                        appState.setBackgroundDividerAngle(
                            element.id,
                            dividerIndex: dividerIndex,
                            angle
                        )
                    },
                    onPartitionSelect: { partition in
                        appState.toggleBackgroundPartition(element.id, partition)
                    }
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("裁剪")
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                    Slider(
                        value: Binding(
                            get: { Double(settings.cropScale) },
                            set: { appState.setBackgroundCropScale(element.id, CGFloat($0)) }
                        ),
                        in: Double(BackgroundElementSettings.minimumCropScale)...Double(BackgroundElementSettings.maximumCropScale)
                    )
                    .tint(LF.header)
                    Text(String(format: "%.1f×", settings.cropScale))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                        .frame(width: 34, alignment: .trailing)
                }
                HStack {
                    Text("图片缩放")
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                    Spacer()
                    Button("重置") {
                        appState.setBackgroundCropScale(element.id, 1)
                        appState.setBackgroundCropOffset(element.id, .zero)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.header)
                    Button {
                        appState.rotateBackground90(element.id)
                    } label: {
                        Label("旋转90°", systemImage: "rotate.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.header)
                }
            }

            inspectorFooter("点击画布空白处可返回画布背景设置")
        }
    }

    private func backgroundDividerLayoutLockBinding(for elementID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                appState.composition?.elements.first(where: { $0.id == elementID })?
                    .backgroundSettings?.isDividerLayoutLocked ?? false
            },
            set: { locked in
                appState.setBackgroundDividerLayoutLocked(elementID, locked)
            }
        )
    }

    private var backgroundInspectorHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .font(.headline.weight(.semibold))
                .foregroundStyle(LF.selectionText)
                .frame(width: 32, height: 32)
                .background(LF.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("画布背景")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.textPrimary)
                Text("比例、颜色和背景图案")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func inspectorFooter(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.tap")
                .font(.caption2.weight(.semibold))
            Text(message)
                .font(.caption2)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(LF.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LF.surface2.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func inspectorChoiceRow<T: CaseIterable & Identifiable & Equatable>(
        title: LocalizedStringKey,
        items: T.AllCases,
        selected: T,
        action: @escaping (T) -> Void
    ) -> some View where T.AllCases: RandomAccessCollection {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        EditorOptionChip(title: itemTitle(item), isSelected: item == selected) {
                            action(item)
                        }
                    }
                }
            }
        }
    }

    private func partitionChoiceRow(
        title: LocalizedStringKey,
        count: Int,
        selected: Int,
        action: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<count, id: \.self) { partition in
                        EditorOptionChip(title: "区域 \(partition + 1)", isSelected: partition == selected) {
                            action(partition)
                        }
                    }
                }
            }
        }
    }

    private func itemTitle<T>(_ item: T) -> String {
        if let region = item as? BackgroundRegion { return region.title }
        if let edge = item as? BackgroundEdgeStyle { return edge.title }
        if let edge = item as? CanvasEdgeStyle { return edge.title }
        if let splitCount = item as? BackgroundSplitCount { return splitCount.title }
        return ""
    }

    // MARK: - 滤镜

    private func filterPicker(_ element: CompositionElement) -> some View {
        Group {
            if let composition = appState.composition {
                ElementFilterOptionPicker(
                    element: element,
                    composition: composition,
                    currentTime: appState.currentTime,
                    previewRevision: appState.clipStyleVersion,
                    selectedFilter: element.filter ?? .none
                ) { filter in
                    appState.setElementFilter(element.id, filter == .none ? nil : filter)
                }
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - 文字编辑

    private func textEditor(_ text: TextElement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文字")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            TextFormattingControls(text: text)
                .environmentObject(appState)
        }
    }

    // MARK: - 元素背景图案

    private func elementBackgroundPicker(_ element: CompositionElement) -> some View {
        BackgroundPatternEditor(style: element.backgroundPattern) { style in
            appState.setElementBackground(element.id, style)
        }
    }

    // MARK: - 贴纸风格

    private func stickerStylePicker(_ clip: SegmentedClip, element: CompositionElement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let composition = appState.composition {
                StickerStyleOptionPicker(
                    clip: clip,
                    element: element,
                    composition: composition,
                    currentTime: appState.currentTime,
                    selectedStyle: clip.stickerStyle
                ) { style in
                    appState.setClipStickerStyle(clip.id, style)
                }
            }
            // 自定义描边和漫画风格都支持三档粗细；颜色仅对自定义描边生效。
            if clip.stickerStyle == .customOutline || clip.stickerStyle == .comic {
                HStack(spacing: 8) {
                    ForEach(EdgeThickness.allCases) { thickness in
                        EditorOptionChip(
                            title: thickness.title,
                            isSelected: clip.edgeThickness == thickness
                        ) {
                            appState.setClipEdgeThickness(clip.id, thickness)
                        }
                    }
                }
                if clip.stickerStyle == .customOutline {
                    let customColorBinding = Binding<Color>(
                        get: { Color(hex: clip.edgeColorHex) },
                        set: { appState.setClipEdgeColor(clip.id, $0.hexRGB) }
                    )
                    HStack(spacing: 4) {
                        ForEach(edgeColors, id: \.hex) { color in
                            let isSelected = clip.edgeColorHex.uppercased() == color.hex
                            Button {
                                appState.setClipEdgeColor(clip.id, color.hex)
                            } label: {
                                Circle()
                                    .fill(Color(hex: color.hex))
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        Circle().strokeBorder(
                                            isSelected ? LF.selectionStroke : LF.surface2,
                                            lineWidth: isSelected ? 2.5 : 1
                                        )
                                    }
                                    .frame(width: 40, height: 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.name)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                        CompactCustomColorPicker(
                            selection: customColorBinding,
                            accessibilityLabel: "更多描边颜色"
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 描边可选颜色
    private let edgeColors: [(name: String, hex: String)] = [
        ("白", "FFFFFF"), ("黑", "000000"), ("灰", "B8BDC9"), ("金", "E8C05C"),
        ("红", "E74C3C"), ("粉", "FF9FF3"), ("蓝", "54A0FF"),
        ("绿", "1DD1A1"), ("紫", "8B7CF6")
    ]

    // MARK: - 播放倍速

    /// 素材播放倍速档位（0.5~2x，简单分数，帧对齐友好）
    private let speedOptions: [Double] = [0.5, 0.8, 1, 1.5, 2]

    private func speedPicker(_ clip: SegmentedClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("倍速")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                Text("时间轴时长 = 素材时长 ÷ 倍速")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary.opacity(0.6))
            }
            HStack(spacing: 8) {
                ForEach(speedOptions, id: \.self) { speed in
                    let isCurrent = abs(clip.playbackSpeed - speed) < 0.001
                    EditorOptionChip(
                        title: "\(speed == speed.rounded() ? String(Int(speed)) : String(format: "%.1f", speed))x",
                        isSelected: isCurrent
                    ) {
                        appState.setClipPlaybackSpeed(clip.id, speed)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 音频段

    private func audioInspector(_ clip: AudioClip) -> some View {
        VStack(spacing: 10) {
            HStack {
                Label("音轨片段", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(role: .destructive) { appState.deleteAudio(clip.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                slider(
                    label: "音量",
                    value: Binding(
                        get: { Double(clip.volume) },
                        set: { value in
                            appState.updateAudio(clip.id) { $0.volume = Float(value) }
                        }
                    ),
                    range: 0...1,
                    text: "\(safePercent(Double(clip.volume)))%"
                )
                slider(
                    label: "淡入",
                    value: Binding(
                        get: { clip.fadeIn },
                        set: { value in
                            appState.updateAudio(clip.id) { $0.fadeIn = value }
                        }
                    ),
                    range: 0...2,
                    text: String(format: "%.1f s", clip.fadeIn)
                )
                slider(
                    label: "淡出",
                    value: Binding(
                        get: { clip.fadeOut },
                        set: { value in
                            appState.updateAudio(clip.id) { $0.fadeOut = value }
                        }
                    ),
                    range: 0...2,
                    text: String(format: "%.1f s", clip.fadeOut)
                )
            }
        }
    }

    /// 防 NaN 的百分比显示
    private func safePercent(_ value: Double) -> Int {
        let percent = value * 100
        return percent.isFinite ? Int(percent.rounded()) : 0
    }

    private func slider(
        label: String, value: Binding<Double>, range: ClosedRange<Double>, text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                Spacer()
                Text(text)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LF.textSecondary)
            }
            Slider(value: value, in: range)
                .tint(LF.gold)
        }
        .frame(maxWidth: .infinity)
    }
}

struct BackgroundFillPreview: View {
    let frame: CGImage
    let canvasAspect: CGFloat
    let canvasSize: CGSize
    let settings: BackgroundElementSettings
    let onPartitionTap: (Int) -> Void
    let onDividerOffsetChange: (Int, CGFloat) -> Void
    let onDividerPivotChange: (Int, CGPoint) -> Void
    let onCropScaleChange: (CGFloat) -> Void
    let onCropOffsetChange: (CGPoint) -> Void
    @State private var activeDividerIndex: Int?
    @State private var dividerOffsetAtDragStart: CGFloat = 0
    @State private var activePivotIndex: Int?
    @State private var imageDragStartOffset: CGPoint?
    @State private var imageScaleStart: CGFloat?

    init(
        frame: CGImage,
        canvasAspect: CGFloat,
        canvasSize: CGSize,
        settings: BackgroundElementSettings,
        onPartitionTap: @escaping (Int) -> Void,
        onDividerOffsetChange: @escaping (Int, CGFloat) -> Void,
        onDividerPivotChange: @escaping (Int, CGPoint) -> Void = { _, _ in },
        onCropScaleChange: @escaping (CGFloat) -> Void = { _ in },
        onCropOffsetChange: @escaping (CGPoint) -> Void = { _ in }
    ) {
        self.frame = frame
        self.canvasAspect = canvasAspect
        self.canvasSize = canvasSize
        self.settings = settings
        self.onPartitionTap = onPartitionTap
        self.onDividerOffsetChange = onDividerOffsetChange
        self.onDividerPivotChange = onDividerPivotChange
        self.onCropScaleChange = onCropScaleChange
        self.onCropOffsetChange = onCropOffsetChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("编辑画面 · 拖动分割线调整位置 · 沿线拖动圆点调整旋转中心")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)

            GeometryReader { geometry in
                let rect = CGRect(origin: .zero, size: geometry.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white)

                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .rotationEffect(.degrees(Double(settings.rotationQuarterTurns * 90)))
                        .scaleEffect(rotationFillScale(in: geometry.size))
                        .scaleEffect(settings.cropScale)
                        .offset(
                            x: settings.cropOffset.x * geometry.size.width / max(canvasSize.width, 1),
                            y: -settings.cropOffset.y * geometry.size.height / max(canvasSize.height, 1)
                        )
                        .clipped()
                        .clipShape(BackgroundPartitionShape(settings: settings))

                    BackgroundDividerShape(settings: settings)
                        .stroke(LF.header.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

                    if !settings.dividerLines.isEmpty {
                        ForEach(0..<dividerCount, id: \.self) { index in
                            dividerHandle(index: index, in: rect)
                            pivotHandle(index: index, in: rect)
                        }

                        Text("区域 \(settings.selectedPartition + 1)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LF.selectionText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                        .background(LF.selectionFill, in: Capsule())
                            .position(selectedLabelPosition(in: rect))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(LF.header.opacity(0.45), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if let partition = partition(at: location, in: rect) {
                        onPartitionTap(partition)
                    }
                }
                .simultaneousGesture(dividerDragGesture(in: rect))
                .simultaneousGesture(pivotDragGesture(in: rect))
                .simultaneousGesture(imageDragGesture(in: rect))
                .simultaneousGesture(imageMagnifyGesture())
            }
            .aspectRatio(canvasAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
    }

    private func selectedLabelPosition(in rect: CGRect) -> CGPoint {
        let point = BackgroundPartitionShape.samplePoint(
            settings: settings,
            in: rect
        )
        return CGPoint(x: point.x, y: point.y)
    }

    private func rotationFillScale(in size: CGSize) -> CGFloat {
        let turns = ((settings.rotationQuarterTurns % 4) + 4) % 4
        guard turns % 2 == 1 else { return 1 }
        return max(size.width / max(size.height, 1), size.height / max(size.width, 1))
    }

    private func partition(at point: CGPoint, in rect: CGRect) -> Int? {
        BackgroundPartitionGeometry.partition(at: point, settings: settings, in: rect)
    }

    private var dividerCount: Int {
        settings.dividerLines.count
    }

    @ViewBuilder
    private func dividerHandle(index: Int, in rect: CGRect) -> some View {
        let point = BackgroundPartitionShape.dividerCenter(for: index, settings: settings, in: rect)
        let isActive = activeDividerIndex == index
        Circle()
            .fill(isActive ? LF.selectionStroke : LF.header)
            .frame(width: isActive ? 22 : 18, height: isActive ? 22 : 18)
            .overlay {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(Double(
                        90 - BackgroundPartitionGeometry.angle(for: index, settings: settings)
                    )))
            }
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .position(point)
            .allowsHitTesting(false)
    }

    private func dividerDragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard pivotIndex(near: value.startLocation, in: rect) == nil else { return }
                let draggedDividerIndex: Int
                let startingOffset: CGFloat
                if let activeDividerIndex {
                    draggedDividerIndex = activeDividerIndex
                    startingOffset = dividerOffsetAtDragStart
                } else {
                    guard let nearest = dividerIndex(near: value.startLocation, in: rect) else { return }
                    draggedDividerIndex = nearest
                    startingOffset = BackgroundDividerGeometry.offset(
                        for: nearest,
                        settings: settings
                    )
                    activeDividerIndex = nearest
                    dividerOffsetAtDragStart = startingOffset
                }

                let normal = BackgroundPartitionShape.normal(for: draggedDividerIndex, settings: settings)
                let extent = BackgroundDividerGeometry.extent(in: rect, normal: normal)
                guard extent > 0.0001 else { return }
                let projectedTranslation = value.translation.width * normal.x
                    + value.translation.height * normal.y
                onDividerOffsetChange(
                    draggedDividerIndex,
                    BackgroundDividerGeometry.clampedOffset(startingOffset + projectedTranslation / extent)
                )
            }
            .onEnded { _ in
                activeDividerIndex = nil
                dividerOffsetAtDragStart = 0
            }
    }

    @ViewBuilder
    private func pivotHandle(index: Int, in rect: CGRect) -> some View {
        let point = BackgroundPartitionGeometry.pivot(
            for: index,
            in: rect,
            settings: settings,
            coordinateSpace: .screen
        )
        let isActive = activePivotIndex == index
        Circle()
            .fill(isActive ? LF.gold : LF.selectionStroke)
            .frame(width: isActive ? 25 : 21, height: isActive ? 25 : 21)
            .overlay {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay {
                Circle().stroke(.white.opacity(0.85), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .position(point)
            .allowsHitTesting(false)
    }

    private func pivotDragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let index: Int
                if let activePivotIndex {
                    index = activePivotIndex
                } else {
                    guard let nearest = pivotIndex(near: value.startLocation, in: rect) else { return }
                    index = nearest
                    activePivotIndex = nearest
                }
                let projected = BackgroundPartitionGeometry.projectedPivot(
                    at: value.location,
                    for: index,
                    settings: settings,
                    in: rect,
                    coordinateSpace: .screen
                )
                let pivot = BackgroundPartitionGeometry.normalizedPivot(
                    at: projected,
                    in: rect,
                    coordinateSpace: .screen
                )
                onDividerPivotChange(index, pivot)
            }
            .onEnded { _ in
                activePivotIndex = nil
            }
    }

    /// 非分割线区域拖动图片取景；与分割线拖动共用同一块编辑画面，
    /// 从分割线附近开始时让分割线手势优先，避免两个参数同时变化。
    private func imageDragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard dividerIndex(near: value.startLocation, in: rect) == nil,
                      pivotIndex(near: value.startLocation, in: rect) == nil else { return }
                let startOffset = imageDragStartOffset ?? settings.cropOffset
                imageDragStartOffset = startOffset
                let dx = value.translation.width * canvasSize.width / max(rect.width, 1)
                let dy = -value.translation.height * canvasSize.height / max(rect.height, 1)
                onCropOffsetChange(
                    CGPoint(x: startOffset.x + dx, y: startOffset.y + dy)
                )
            }
            .onEnded { _ in
                imageDragStartOffset = nil
            }
    }

    private func imageMagnifyGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let startScale = imageScaleStart ?? settings.cropScale
                imageScaleStart = startScale
                onCropScaleChange(min(
                    max(startScale * value, BackgroundElementSettings.minimumCropScale),
                    BackgroundElementSettings.maximumCropScale
                ))
            }
            .onEnded { _ in
                imageScaleStart = nil
            }
    }

    private func dividerIndex(near point: CGPoint, in rect: CGRect) -> Int? {
        let threshold = max(16, min(rect.width, rect.height) * 0.1)
        return BackgroundPartitionGeometry.dividerIndex(
            near: point,
            settings: settings,
            in: rect,
            threshold: threshold
        )
    }

    private func pivotIndex(near point: CGPoint, in rect: CGRect) -> Int? {
        let threshold = max(18, min(rect.width, rect.height) * 0.08)
        let count = dividerCount
        guard count > 0 else { return nil }
        let candidates = (0..<count).map { index in
            let pivot = BackgroundPartitionGeometry.pivot(
                for: index,
                in: rect,
                settings: settings,
                coordinateSpace: .screen
            )
            let distance = hypot(point.x - pivot.x, point.y - pivot.y)
            return (index, distance)
        }
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= threshold else {
            return nil
        }
        return nearest.0
    }
}

/// 背景遮罩的 SwiftUI 对应路径；检查器预览与画布命中测试共用它，保证可见区域和可选区域一致。
struct BackgroundPartitionShape: Shape {
    let settings: BackgroundElementSettings

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !settings.dividerLines.isEmpty else {
            // 未分区的素材覆盖整幅画布；有分割线时，空分区才表示尚未分配。
            path.addRect(rect)
            return path
        }
        guard !settings.resolvedAssignedPartitions.isEmpty else {
            return path
        }
        let polygons = BackgroundPartitionGeometry.assignedPolygons(
            for: settings,
            in: rect,
            coordinateSpace: .screen
        )
        for polygon in polygons {
            guard let first = polygon.first else { continue }
            path.move(to: first)
            for point in polygon.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        return path
    }

    static func radians(_ degrees: CGFloat) -> CGFloat {
        BackgroundPartitionGeometry.radians(degrees)
    }

    static func normal(for dividerIndex: Int, settings: BackgroundElementSettings) -> CGPoint {
        BackgroundPartitionGeometry.normal(
            for: dividerIndex,
            settings: settings,
            coordinateSpace: .screen
        )
    }

    static func dividerCenter(
        for dividerIndex: Int,
        settings: BackgroundElementSettings,
        in rect: CGRect
    ) -> CGPoint {
        BackgroundPartitionGeometry.dividerCenter(
            for: dividerIndex,
            settings: settings,
            in: rect,
            coordinateSpace: .screen
        )
    }

    static func samplePoint(settings: BackgroundElementSettings, in rect: CGRect) -> CGPoint {
        BackgroundPartitionGeometry.samplePoint(settings: settings, in: rect)
    }

    static func regionCount(settings: BackgroundElementSettings, in rect: CGRect) -> Int {
        BackgroundPartitionGeometry.regionCount(for: settings, in: rect)
    }
}

struct BackgroundDividerShape: Shape {
    let settings: BackgroundElementSettings

    func path(in rect: CGRect) -> Path {
        guard !settings.dividerLines.isEmpty else { return Path() }
        let length = max(rect.width, rect.height) * 2
        var path = Path()
        for dividerIndex in settings.dividerLines.indices {
            let secondAngle = BackgroundPartitionGeometry.radians(
                BackgroundPartitionGeometry.angle(for: dividerIndex, settings: settings)
            )
            let secondDirection = CGPoint(x: cos(secondAngle), y: -sin(secondAngle))
            let secondCenter = BackgroundPartitionShape.dividerCenter(for: dividerIndex, settings: settings, in: rect)
            path.move(to: CGPoint(x: secondCenter.x - secondDirection.x * length, y: secondCenter.y - secondDirection.y * length))
            path.addLine(to: CGPoint(x: secondCenter.x + secondDirection.x * length, y: secondCenter.y + secondDirection.y * length))
        }
        return path
    }
}
