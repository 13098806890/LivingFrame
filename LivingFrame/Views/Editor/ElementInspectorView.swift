import LivingFrameCore
import SwiftUI
import UIKit

/// 检查器：按选中类型分派（视频元素 / 音频段）
struct ElementInspectorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // 底部属性面板：高度受限（外部 frame），内容多时内部滚动
        // sheet 导航栏已经提供了上下文标题，这里不再重复嵌套“检查器”标题。
        SectionCard(title: nil) {
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
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - 背景检查器

    /// 纯色背景
    private let bgColors: [(name: String, hex: String)] = [
        ("白色", "FFFFFF"), ("微信背景色", "EDEDED"), ("黑色", "000000")
    ]

    private var backgroundInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            backgroundInspectorHeader
            // 画幅比例
            HStack(spacing: 8) {
                Text("比例")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                ForEach(CanvasAspect.allCases) { aspect in
                    Button {
                        appState.setCanvasAspect(aspect)
                    } label: {
                        Text(aspect.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                appState.composition?.canvasRect.size == aspect.canvasSize ? LF.selectionFill : LF.surface2,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke(
                                        appState.composition?.canvasRect.size == aspect.canvasSize ? LF.selectionStroke : .clear,
                                        lineWidth: 1.5
                                    )
                            }
                            .foregroundStyle(appState.composition?.canvasRect.size == aspect.canvasSize ? LF.selectionText : LF.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // 纯色
            HStack(spacing: 10) {
                Button {
                    appState.setTransparentBackground()
                } label: {
                    CheckerboardView()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    appState.composition?.background.kind == .clear ? LF.selectionStroke : LF.surface2,
                                    lineWidth: appState.composition?.background.kind == .clear ? 2.5 : 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("透明背景")
                ForEach(bgColors, id: \.hex) { color in
                    Button {
                        appState.setBackground(color: color.hex)
                    } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: color.hex))
                            .frame(width: 44, height: 44)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        isBgColor(color.hex) ? LF.selectionStroke : LF.surface2,
                                        lineWidth: isBgColor(color.hex) ? 2.5 : 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            inspectorChoiceRow(
                title: "画布外缘",
                items: CanvasEdgeStyle.allCases,
                selected: appState.composition?.canvasEdgeStyle ?? .none
            ) { style in
                appState.setCanvasEdgeStyle(style)
            }
            // 图案叠加（横线/斜线/网格/马赛克）
            Text("图案叠加")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            HStack(spacing: 8) {
                Button {
                    appState.setBackgroundPattern(nil)
                } label: {
                    Text("无")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            bgOverlay == nil ? LF.selectionFill : LF.surface2,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(bgOverlay == nil ? LF.selectionStroke : .clear, lineWidth: 1.5)
                        }
                        .foregroundStyle(bgOverlay == nil ? LF.selectionText : LF.textPrimary)
                }
                .buttonStyle(.plain)
                ForEach(linePatterns) { pattern in
                    Button {
                        var style = bgOverlay ?? BackgroundPatternStyle()
                        style.pattern = pattern
                        // 切换图案时重置默认参数，避免继承旧图案的异常值
                        if pattern == .mosaic {
                            style.lineWidth = 48
                            style.spacing = 48
                            style.angle = 0
                        } else {
                            style.lineWidth = 4
                            style.spacing = 36
                            style.angle = 0
                        }
                        appState.setBackgroundPattern(style)
                    } label: {
                        Text(pattern.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                bgOverlay?.pattern == pattern ? LF.selectionFill : LF.surface2,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke(bgOverlay?.pattern == pattern ? LF.selectionStroke : .clear, lineWidth: 1.5)
                            }
                            .foregroundStyle(bgOverlay?.pattern == pattern ? LF.selectionText : LF.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if bgOverlay != nil {
                // 粗细（横线=线宽，马赛克=方块大小）
                HStack(spacing: 8) {
                    ForEach(patternOptions(bgOverlay?.pattern).widths, id: \.0) { option in
                        Button {
                            var style = bgOverlay ?? BackgroundPatternStyle()
                            style.lineWidth = option.1
                            appState.setBackgroundPattern(style)
                        } label: {
                            Text(option.0)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    abs((bgOverlay?.lineWidth ?? 0) - option.1) < 0.1 ? LF.selectionFill : LF.surface2,
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(
                                            abs((bgOverlay?.lineWidth ?? 0) - option.1) < 0.1 ? LF.selectionStroke : .clear,
                                            lineWidth: 1.5
                                        )
                                }
                                .foregroundStyle(abs((bgOverlay?.lineWidth ?? 0) - option.1) < 0.1 ? LF.selectionText : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // 疏密度（仅横线）
                if bgOverlay?.pattern != .mosaic {
                    HStack(spacing: 8) {
                        ForEach(patternOptions(bgOverlay?.pattern).spacing, id: \.0) { option in
                            Button {
                                var style = bgOverlay ?? BackgroundPatternStyle()
                                style.spacing = option.1
                                appState.setBackgroundPattern(style)
                            } label: {
                                Text(option.0)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        abs((bgOverlay?.spacing ?? 0) - option.1) < 1 ? LF.selectionFill : LF.surface2,
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(
                                                abs((bgOverlay?.spacing ?? 0) - option.1) < 1 ? LF.selectionStroke : .clear,
                                                lineWidth: 1.5
                                            )
                                    }
                                    .foregroundStyle(abs((bgOverlay?.spacing ?? 0) - option.1) < 1 ? LF.selectionText : LF.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(edgeColors, id: \.hex) { color in
                        Button {
                            var style = bgOverlay ?? BackgroundPatternStyle()
                            style.colorHex = color.hex
                            appState.setBackgroundPattern(style)
                        } label: {
                            Circle()
                                .fill(Color(hex: color.hex))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle().stroke(
                                        bgOverlay?.colorHex == color.hex ? LF.selectionStroke : LF.surface2,
                                        lineWidth: bgOverlay?.colorHex == color.hex ? 2.5 : 1
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                // 角度（仅横线，0 = 横线，90 = 竖线，45/135 = 斜线）
                if bgOverlay?.pattern != .mosaic {
                    HStack(spacing: 8) {
                        Text("角度")
                            .font(.caption2)
                            .foregroundStyle(LF.textSecondary)
                        Slider(
                            value: Binding(
                                get: { bgOverlay?.angle ?? 0 },
                                set: { value in
                                    var style = bgOverlay ?? BackgroundPatternStyle()
                                    style.angle = value
                                    appState.setBackgroundPattern(style)
                                }
                            ),
                            in: 0...180
                        )
                        .tint(LF.selectionStroke)
                        Text("\(Int(bgOverlay?.angle ?? 0))°")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(LF.textSecondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// 可选线条图案：横线（角度任意）+ 马赛克
    private let linePatterns: [BackgroundPattern] = [.horizontal, .mosaic]

    /// 图案参数档位：横线=线宽+疏密度；马赛克=方块大小
    private func patternOptions(_ pattern: BackgroundPattern?) -> (
        widths: [(String, CGFloat)],
        spacing: [(String, CGFloat)]
    ) {
        if pattern == .mosaic {
            return ([("小", 32), ("中", 48), ("大", 64)], [])
        }
        return (
            [("细", 2), ("中", 4), ("粗", 8)],
            [("疏", 48), ("中", 36), ("密", 24)]
        )
    }

    /// 当前背景图案叠加层
    private var bgOverlay: BackgroundPatternStyle? {
        appState.composition?.background.patternOverlay
    }

    private func isBgColor(_ hex: String) -> Bool {
        guard let bg = appState.composition?.background, case .solid = bg.kind else { return false }
        return bg.topColor == hex
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
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(LF.selectionText)
                    .frame(width: 32, height: 32)
                    .background(LF.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(element.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LF.textPrimary)
                        .lineLimit(1)
                    Text("图层属性")
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                }

                Spacer()
                HStack(spacing: 5) {
                    Button { appState.moveElementZ(element.id, up: false) } label: {
                        Image(systemName: "square.3.layers.3d.down.right")
                    }
                    .buttonStyle(.plain)
                    Button { appState.moveElementZ(element.id, up: true) } label: {
                        Image(systemName: "square.3.layers.3d.up.right")
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) { appState.deleteElement(element.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

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
                    stickerStylePicker(clip)
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

    private func elementInspectorIcon(for element: CompositionElement) -> String {
        switch element.kind {
        case .clip: return "film"
        case .background: return "photo.on.rectangle"
        case .decoration: return "face.smiling"
        case .effect: return "sparkles"
        case .text: return "textformat"
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
                        Button { action(item) } label: {
                            Text(itemTitle(item))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(item == selected ? LF.selectionFill : LF.surface2, in: Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(item == selected ? LF.selectionStroke : .clear, lineWidth: 1.5)
                                }
                                .foregroundStyle(item == selected ? LF.selectionText : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
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
                        Button { action(partition) } label: {
                            Text("区域 \(partition + 1)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(partition == selected ? LF.selectionFill : LF.surface2, in: Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(partition == selected ? LF.selectionStroke : .clear, lineWidth: 1.5)
                                }
                                .foregroundStyle(partition == selected ? LF.selectionText : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("滤镜")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ElementFilter.allCases) { filter in
                        Button {
                            appState.setElementFilter(element.id, filter == .none ? nil : filter)
                        } label: {
                            Text(filter.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    (element.filter ?? .none) == filter ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle((element.filter ?? .none) == filter ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("背景")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            // 图案类型（无 = 关闭）
            HStack(spacing: 8) {
                Button {
                    appState.setElementBackground(element.id, nil)
                } label: {
                    Text("无")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            element.backgroundPattern == nil ? LF.gold : LF.surface2,
                            in: Capsule()
                        )
                        .foregroundStyle(element.backgroundPattern == nil ? .black : LF.textPrimary)
                }
                .buttonStyle(.plain)
                ForEach(linePatterns) { pattern in
                    Button {
                        var style = element.backgroundPattern ?? BackgroundPatternStyle()
                        style.pattern = pattern
                        // 切换图案时重置默认参数，避免继承旧图案的异常值
                        if pattern == .mosaic {
                            style.lineWidth = 48
                            style.spacing = 48
                            style.angle = 0
                        } else {
                            style.lineWidth = 4
                            style.spacing = 36
                            style.angle = 0
                        }
                        appState.setElementBackground(element.id, style)
                    } label: {
                        Text(pattern.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                element.backgroundPattern?.pattern == pattern ? LF.gold : LF.surface2,
                                in: Capsule()
                            )
                            .foregroundStyle(element.backgroundPattern?.pattern == pattern ? .black : LF.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if element.backgroundPattern != nil {
                // 粗细（横线=线宽，马赛克=方块大小）
                HStack(spacing: 8) {
                    ForEach(patternOptions(element.backgroundPattern?.pattern).widths, id: \.0) { option in
                        Button {
                            var style = element.backgroundPattern ?? BackgroundPatternStyle()
                            style.lineWidth = option.1
                            appState.setElementBackground(element.id, style)
                        } label: {
                            Text(option.0)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    abs((element.backgroundPattern?.lineWidth ?? 0) - option.1) < 0.1 ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(abs((element.backgroundPattern?.lineWidth ?? 0) - option.1) < 0.1 ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // 疏密度（仅横线）
                if element.backgroundPattern?.pattern != .mosaic {
                    HStack(spacing: 8) {
                        ForEach(patternOptions(element.backgroundPattern?.pattern).spacing, id: \.0) { option in
                            Button {
                                var style = element.backgroundPattern ?? BackgroundPatternStyle()
                                style.spacing = option.1
                                appState.setElementBackground(element.id, style)
                            } label: {
                                Text(option.0)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        abs((element.backgroundPattern?.spacing ?? 0) - option.1) < 1 ? LF.gold : LF.surface2,
                                        in: Capsule()
                                    )
                                    .foregroundStyle(abs((element.backgroundPattern?.spacing ?? 0) - option.1) < 1 ? .black : LF.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(edgeColors, id: \.hex) { color in
                        Button {
                            var style = element.backgroundPattern ?? BackgroundPatternStyle()
                            style.colorHex = color.hex
                            appState.setElementBackground(element.id, style)
                        } label: {
                            Circle()
                                .fill(Color(hex: color.hex))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle().stroke(
                                        element.backgroundPattern?.colorHex == color.hex ? LF.gold : LF.surface2,
                                        lineWidth: element.backgroundPattern?.colorHex == color.hex ? 2.5 : 1
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                // 角度（仅横线，0 = 横线，90 = 竖线，45/135 = 斜线）
                if element.backgroundPattern?.pattern != .mosaic {
                    HStack(spacing: 8) {
                        Text("角度")
                            .font(.caption2)
                            .foregroundStyle(LF.textSecondary)
                        Slider(
                            value: Binding(
                                get: { element.backgroundPattern?.angle ?? 0 },
                                set: { value in
                                    var style = element.backgroundPattern ?? BackgroundPatternStyle()
                                    style.angle = value
                                    appState.setElementBackground(element.id, style)
                                }
                            ),
                            in: 0...180
                        )
                        .tint(LF.gold)
                        Text("\(Int(element.backgroundPattern?.angle ?? 0))°")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(LF.textSecondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 贴纸风格

    private func stickerStylePicker(_ clip: SegmentedClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("风格")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StickerStyle.allCases) { style in
                        Button {
                            appState.setClipStickerStyle(clip.id, style)
                        } label: {
                            Text(style.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    clip.stickerStyle == style ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(clip.stickerStyle == style ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // 自定义描边和漫画风格都支持三档粗细；颜色仅对自定义描边生效。
            if clip.stickerStyle == .customOutline || clip.stickerStyle == .comic {
                HStack(spacing: 8) {
                    ForEach(EdgeThickness.allCases) { thickness in
                        Button {
                            appState.setClipEdgeThickness(clip.id, thickness)
                        } label: {
                            Text(thickness.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    clip.edgeThickness == thickness ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(clip.edgeThickness == thickness ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if clip.stickerStyle == .customOutline {
                    HStack(spacing: 10) {
                    ForEach(edgeColors, id: \.hex) { color in
                        Button {
                            appState.setClipEdgeColor(clip.id, color.hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: color.hex))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle().stroke(
                                        clip.edgeColorHex.uppercased() == color.hex ? LF.gold : LF.surface2,
                                        lineWidth: clip.edgeColorHex.uppercased() == color.hex ? 2.5 : 1
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                    }
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
                    Button {
                        appState.setClipPlaybackSpeed(clip.id, speed)
                    } label: {
                        Text("\(speed == speed.rounded() ? String(Int(speed)) : String(format: "%.1f", speed))x")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isCurrent ? LF.gold : LF.surface2, in: Capsule())
                            .foregroundStyle(isCurrent ? .black : LF.textPrimary)
                    }
                    .buttonStyle(.plain)
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
        guard !settings.resolvedAssignedPartitions.isEmpty else {
            return path
        }
        guard !settings.dividerLines.isEmpty else {
            path.addRect(rect)
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
