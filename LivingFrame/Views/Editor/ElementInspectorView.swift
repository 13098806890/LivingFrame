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
