import LivingFrameCore
import SwiftUI

/// 检查器：按选中类型分派（视频元素 / 音频段）
struct ElementInspectorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // 底部属性面板：高度受限（外部 frame），内容多时内部滚动
        SectionCard(title: "检查器") {
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
        }
    }

    // MARK: - 背景检查器

    /// 纯色背景
    private let bgColors: [(name: String, hex: String)] = [
        ("白色", "FFFFFF"), ("微信背景色", "EDEDED"), ("黑色", "000000")
    ]

    private var backgroundInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("背景")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("画布空白处取消选中后返回")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }
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
                                appState.composition?.canvasRect.size == aspect.canvasSize ? LF.gold : LF.surface2,
                                in: Capsule()
                            )
                            .foregroundStyle(appState.composition?.canvasRect.size == aspect.canvasSize ? .black : LF.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // 纯色
            HStack(spacing: 10) {
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
                                        isBgColor(color.hex) ? LF.gold : LF.surface2,
                                        lineWidth: isBgColor(color.hex) ? 2.5 : 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
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
                            bgOverlay == nil ? LF.gold : LF.surface2,
                            in: Capsule()
                        )
                        .foregroundStyle(bgOverlay == nil ? .black : LF.textPrimary)
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
                                bgOverlay?.pattern == pattern ? LF.gold : LF.surface2,
                                in: Capsule()
                            )
                            .foregroundStyle(bgOverlay?.pattern == pattern ? .black : LF.textPrimary)
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
                                    abs((bgOverlay?.lineWidth ?? 0) - option.1) < 0.1 ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(abs((bgOverlay?.lineWidth ?? 0) - option.1) < 0.1 ? .black : LF.textPrimary)
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
                                        abs((bgOverlay?.spacing ?? 0) - option.1) < 1 ? LF.gold : LF.surface2,
                                        in: Capsule()
                                    )
                                    .foregroundStyle(abs((bgOverlay?.spacing ?? 0) - option.1) < 1 ? .black : LF.textPrimary)
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
                                        bgOverlay?.colorHex == color.hex ? LF.gold : LF.surface2,
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
                        .tint(LF.gold)
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
            HStack {
                Text(element.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
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

            if case .background = element.kind {
                backgroundElementInspector(element)
            } else {
                if case .clip(let clipID) = element.kind,
                   let clip = appState.clips.first(where: { $0.id == clipID }) {
                    stickerStylePicker(clip)
                    speedPicker(clip)
                }
                if case .text(let textID) = element.kind,
                   let text = appState.composition?.texts.first(where: { $0.id.uuidString == textID }) {
                    textEditor(text)
                }
                filterPicker(element)
                elementBackgroundPicker(element)
            }
        }
    }

    private func backgroundElementInspector(_ element: CompositionElement) -> some View {
        let settings = element.backgroundSettings ?? BackgroundElementSettings()
        return VStack(alignment: .leading, spacing: 10) {
            if let comp = appState.composition,
               case .background(let backgroundID) = element.kind,
               let frame = BackgroundStore.shared.loadFrame(named: backgroundID, at: appState.currentTime) {
                BackgroundFillPreview(
                    frame: frame,
                    canvasAspect: comp.canvasRect.width / comp.canvasRect.height,
                    canvasSize: comp.canvasRect.size,
                    settings: settings,
                    onPartitionTap: { partition in
                        appState.setBackgroundPartition(element.id, partition)
                    },
                    onDividerOffsetChange: { dividerIndex, offset in
                        appState.setBackgroundDividerOffset(
                            element.id,
                            dividerIndex: dividerIndex,
                            offset: offset
                        )
                    }
                )
            }

            inspectorChoiceRow(
                title: "分区",
                items: BackgroundSplitCount.allCases,
                selected: settings.splitCount
            ) { splitCount in
                appState.setBackgroundSplitCount(element.id, splitCount)
            }

            if settings.splitCount != .full {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("角度")
                            .font(.caption2)
                            .foregroundStyle(LF.textSecondary)
                        Spacer()
                        Text(String(format: "%.0f°", settings.dividerAngle))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(LF.accent)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.dividerAngle) },
                            set: { appState.setBackgroundDividerAngle(element.id, CGFloat($0)) }
                        ),
                        in: 0...180
                    )
                    .tint(LF.accent)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach([CGFloat(0), 30, 45, 60, 90, 120, 135, 150], id: \.self) { angle in
                                Button {
                                    appState.setBackgroundDividerAngle(element.id, angle)
                                } label: {
                                    Text(String(format: "%.0f°", angle))
                                        .font(.caption2.monospacedDigit().weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                            abs(settings.dividerAngle - angle) < 0.5 ? LF.accent : LF.surface2,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(abs(settings.dividerAngle - angle) < 0.5 ? .white : LF.textPrimary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Text(settings.splitCount == .four
                         ? "靠近常用角度时会自动吸附；预览中的两个圆点可分别拖动"
                         : "靠近常用角度时会自动吸附；预览中的圆点可拖动")
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                }

                partitionChoiceRow(
                    title: "填充区域",
                    count: settings.splitCount == .two ? 2 : 4,
                    selected: settings.selectedPartition
                ) { partition in
                    appState.setBackgroundPartition(element.id, partition)
                }
            }

            inspectorChoiceRow(
                title: "边缘",
                items: BackgroundEdgeStyle.allCases,
                selected: settings.edgeStyle
            ) { style in
                appState.setBackgroundEdgeStyle(element.id, style)
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
                        in: 1...4
                    )
                    .tint(LF.accent)
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
                    .foregroundStyle(LF.accent)
                    Button {
                        appState.rotateBackground90(element.id)
                    } label: {
                        Label("旋转90°", systemImage: "rotate.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.accent)
                }
            }
        }
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
                                .background(item == selected ? LF.accent : LF.surface2, in: Capsule())
                                .foregroundStyle(item == selected ? .white : LF.textPrimary)
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
                                .background(partition == selected ? LF.accent : LF.surface2, in: Capsule())
                                .foregroundStyle(partition == selected ? .white : LF.textPrimary)
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
            TextField("输入文字", text: Binding(
                get: { text.text },
                set: { newValue in
                    appState.updateText(text.id) { $0.text = newValue }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.subheadline)
            HStack(spacing: 12) {
                slider(
                    label: "字号",
                    value: Binding(
                        get: { Double(text.fontSize) },
                        set: { value in
                            appState.updateText(text.id) { $0.fontSize = CGFloat(value) }
                        }
                    ),
                    range: 24...300,
                    text: "\(Int(text.fontSize))"
                )
            }
            HStack(spacing: 10) {
                ForEach(textColors, id: \.hex) { color in
                    Button {
                        appState.updateText(text.id) { $0.colorHex = color.hex }
                    } label: {
                        Circle()
                            .fill(Color(hex: color.hex))
                            .frame(width: 24, height: 24)
                            .overlay {
                                Circle().stroke(
                                    text.colorHex.uppercased() == color.hex ? LF.gold : LF.surface2,
                                    lineWidth: text.colorHex.uppercased() == color.hex ? 2.5 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private let textColors: [(name: String, hex: String)] = [
        ("白", "FFFFFF"), ("黑", "000000"), ("金", "E8C05C"), ("红", "E74C3C"),
        ("粉", "FF9FF3"), ("蓝", "54A0FF"), ("绿", "1DD1A1"), ("紫", "8B7CF6")
    ]

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
            // 自定义描边参数：粗细 → 颜色（风格=自定义描边时）
            if clip.stickerStyle == .customOutline {
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

private struct BackgroundFillPreview: View {
    let frame: CGImage
    let canvasAspect: CGFloat
    let canvasSize: CGSize
    let settings: BackgroundElementSettings
    let onPartitionTap: (Int) -> Void
    let onDividerOffsetChange: (Int, CGFloat) -> Void
    @State private var activeDividerIndex: Int?
    @State private var dividerOffsetAtDragStart: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("实时预览 · 点击区域选择图片显示位置 · 拖动圆点平移分割线")
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
                        .stroke(LF.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

                    if settings.splitCount != .full {
                        ForEach(0..<dividerCount, id: \.self) { index in
                            dividerHandle(index: index, in: rect)
                        }

                        Text("区域 \(settings.selectedPartition + 1)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(LF.accent, in: Capsule())
                            .position(selectedLabelPosition(in: rect))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(LF.accent.opacity(0.45), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if let partition = partition(at: location, in: rect) {
                        onPartitionTap(partition)
                    }
                }
                .simultaneousGesture(dividerDragGesture(in: rect))
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
        guard settings.splitCount != .full else { return nil }
        let normal = BackgroundPartitionShape.normal(for: 0, settings: settings)
        let firstCenter = BackgroundPartitionShape.dividerCenter(
            for: 0,
            settings: settings,
            in: rect
        )
        let value = signedDistance(point, from: firstCenter, normal: normal)
        if settings.splitCount == .two {
            return value >= 0 ? 0 : 1
        }
        let secondNormal = BackgroundPartitionShape.normal(for: 1, settings: settings)
        let secondCenter = BackgroundPartitionShape.dividerCenter(
            for: 1,
            settings: settings,
            in: rect
        )
        let secondValue = signedDistance(point, from: secondCenter, normal: secondNormal)
        let firstBit = value >= 0
        let secondBit = secondValue >= 0
        switch (firstBit, secondBit) {
        case (true, true): return 0
        case (false, true): return 1
        case (false, false): return 2
        case (true, false): return 3
        }
    }

    private var dividerCount: Int {
        settings.splitCount == .four ? 2 : (settings.splitCount == .two ? 1 : 0)
    }

    @ViewBuilder
    private func dividerHandle(index: Int, in rect: CGRect) -> some View {
        let point = BackgroundPartitionShape.dividerCenter(for: index, settings: settings, in: rect)
        let isActive = activeDividerIndex == index
        Circle()
            .fill(isActive ? LF.gold : LF.accent)
            .frame(width: isActive ? 22 : 18, height: isActive ? 22 : 18)
            .overlay {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(Double(index == 0
                        ? 90 - settings.dividerAngle
                        : 180 - settings.dividerAngle)))
            }
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .position(point)
            .allowsHitTesting(false)
    }

    private func dividerDragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
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

    private func dividerIndex(near point: CGPoint, in rect: CGRect) -> Int? {
        guard dividerCount > 0 else { return nil }
        let threshold = max(16, min(rect.width, rect.height) * 0.1)
        let candidates = (0..<dividerCount).map { index -> (index: Int, distance: CGFloat) in
            let center = BackgroundPartitionShape.dividerCenter(for: index, settings: settings, in: rect)
            let normal = BackgroundPartitionShape.normal(for: index, settings: settings)
            return (index, abs(signedDistance(point, from: center, normal: normal)))
        }
        guard let nearest = candidates.min(by: { $0.distance < $1.distance }),
              nearest.distance <= threshold else { return nil }
        return nearest.index
    }

    private func signedDistance(_ point: CGPoint, from center: CGPoint, normal: CGPoint) -> CGFloat {
        (point.x - center.x) * normal.x + (point.y - center.y) * normal.y
    }
}

private struct BackgroundPartitionShape: Shape {
    let settings: BackgroundElementSettings

    func path(in rect: CGRect) -> Path {
        guard settings.splitCount != .full else { return Path(rect) }
        let polygon = polygon(in: rect)
        var path = Path()
        guard let first = polygon.first else { return path }
        path.move(to: first)
        for point in polygon.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    static func radians(_ degrees: CGFloat) -> CGFloat {
        let normalized = (degrees.isFinite ? degrees : 45).truncatingRemainder(dividingBy: 180)
        return (normalized < 0 ? normalized + 180 : normalized) * .pi / 180
    }

    static func normal(for dividerIndex: Int, settings: BackgroundElementSettings) -> CGPoint {
        let angle = radians(settings.dividerAngle)
        let direction = CGPoint(x: cos(angle), y: -sin(angle))
        return dividerIndex == 0
            ? CGPoint(x: -direction.y, y: direction.x)
            : CGPoint(x: -direction.x, y: -direction.y)
    }

    static func dividerCenter(
        for dividerIndex: Int,
        settings: BackgroundElementSettings,
        in rect: CGRect
    ) -> CGPoint {
        BackgroundDividerGeometry.center(
            in: rect,
            normal: normal(for: dividerIndex, settings: settings),
            offset: BackgroundDividerGeometry.offset(for: dividerIndex, settings: settings)
        )
    }

    static func samplePoint(settings: BackgroundElementSettings, in rect: CGRect) -> CGPoint {
        let firstNormal = normal(for: 0, settings: settings)
        let firstCenter = dividerCenter(for: 0, settings: settings, in: rect)
        if settings.splitCount == .two {
            let sign: CGFloat = settings.selectedPartition == 0 ? 1 : -1
            let distance = BackgroundDividerGeometry.extent(in: rect, normal: firstNormal) * 0.24 * sign
            return clampedToRect(
                CGPoint(
                    x: firstCenter.x + firstNormal.x * distance,
                    y: firstCenter.y + firstNormal.y * distance
                ),
                rect: rect
            )
        }
        let secondNormal = normal(for: 1, settings: settings)
        let firstSign: CGFloat = settings.selectedPartition == 0 || settings.selectedPartition == 3 ? 1 : -1
        let secondSign: CGFloat = settings.selectedPartition == 0 || settings.selectedPartition == 1 ? 1 : -1
        let firstDistance = BackgroundDividerGeometry.extent(in: rect, normal: firstNormal) * 0.2 * firstSign
        let secondDistance = BackgroundDividerGeometry.extent(in: rect, normal: secondNormal) * 0.2 * secondSign
        let sample = CGPoint(
            x: firstCenter.x + firstNormal.x * firstDistance + secondNormal.x * secondDistance,
            y: firstCenter.y + firstNormal.y * firstDistance + secondNormal.y * secondDistance
        )
        return clampedToRect(
            sample,
            rect: rect
        )
    }

    private func polygon(in rect: CGRect) -> [CGPoint] {
        let angle = Self.radians(settings.dividerAngle)
        let direction = CGPoint(x: cos(angle), y: -sin(angle))
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let firstCenter = Self.dividerCenter(for: 0, settings: settings, in: rect)
        let base = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        if settings.splitCount == .two {
            let sign: CGFloat = settings.selectedPartition == 0 ? 1 : -1
            return clipped(base, center: firstCenter, normal: normal, sign: sign)
        }
        let secondNormal = Self.normal(for: 1, settings: settings)
        let secondCenter = Self.dividerCenter(for: 1, settings: settings, in: rect)
        let firstSign: CGFloat = settings.selectedPartition == 0 || settings.selectedPartition == 3 ? 1 : -1
        let secondSign: CGFloat = settings.selectedPartition == 0 || settings.selectedPartition == 1 ? 1 : -1
        return clipped(
            clipped(base, center: firstCenter, normal: normal, sign: firstSign),
            center: secondCenter,
            normal: secondNormal,
            sign: secondSign
        )
    }

    private func clipped(_ polygon: [CGPoint], center: CGPoint, normal: CGPoint, sign: CGFloat) -> [CGPoint] {
        guard !polygon.isEmpty else { return [] }
        var result: [CGPoint] = []
        for index in polygon.indices {
            let current = polygon[index]
            let previous = polygon[(index + polygon.count - 1) % polygon.count]
            let currentValue = distance(current, center: center, normal: normal, sign: sign)
            let previousValue = distance(previous, center: center, normal: normal, sign: sign)
            let currentInside = currentValue >= 0
            let previousInside = previousValue >= 0
            if currentInside != previousInside {
                let denominator = previousValue - currentValue
                let progress = abs(denominator) > 0.0001 ? previousValue / denominator : 0
                result.append(CGPoint(
                    x: previous.x + (current.x - previous.x) * progress,
                    y: previous.y + (current.y - previous.y) * progress
                ))
            }
            if currentInside { result.append(current) }
        }
        return result
    }

    private func distance(_ point: CGPoint, center: CGPoint, normal: CGPoint, sign: CGFloat) -> CGFloat {
        ((point.x - center.x) * normal.x + (point.y - center.y) * normal.y) * sign
    }

    private static func clampedToRect(_ point: CGPoint, rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX + 24), rect.maxX - 24),
            y: min(max(point.y, rect.minY + 16), rect.maxY - 16)
        )
    }
}

private struct BackgroundDividerShape: Shape {
    let settings: BackgroundElementSettings

    func path(in rect: CGRect) -> Path {
        guard settings.splitCount != .full else { return Path() }
        let angle = BackgroundPartitionShape.radians(settings.dividerAngle)
        let direction = CGPoint(x: cos(angle), y: -sin(angle))
        let firstCenter = BackgroundPartitionShape.dividerCenter(for: 0, settings: settings, in: rect)
        let length = max(rect.width, rect.height) * 2
        var path = Path()
        path.move(to: CGPoint(x: firstCenter.x - direction.x * length, y: firstCenter.y - direction.y * length))
        path.addLine(to: CGPoint(x: firstCenter.x + direction.x * length, y: firstCenter.y + direction.y * length))
        if settings.splitCount == .four {
            let perpendicular = CGPoint(x: -direction.y, y: direction.x)
            let secondCenter = BackgroundPartitionShape.dividerCenter(for: 1, settings: settings, in: rect)
            path.move(to: CGPoint(x: secondCenter.x - perpendicular.x * length, y: secondCenter.y - perpendicular.y * length))
            path.addLine(to: CGPoint(x: secondCenter.x + perpendicular.x * length, y: secondCenter.y + perpendicular.y * length))
        }
        return path
    }
}
