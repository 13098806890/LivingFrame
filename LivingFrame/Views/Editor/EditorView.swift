import LivingFrameCore
import SwiftUI

/// 编辑器工具类型（参考 ImgPlay 底部工具栏）
enum EditorTool: String, CaseIterable, Identifiable {
    case asset       // 素材（从素材库添加）
    case canvas      // 画布（比例 + 背景）
    case text        // 文本（添加/编辑文字）
    case sticker     // 贴纸（内置贴纸库）
    case border      // 边框（人物描边 + 画面外框）
    case draw        // 涂鸦（画笔）
    case filter      // 滤镜
    case frame       // 帧（帧选择/编辑）
    case crop        // 裁剪

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asset: "素材"
        case .canvas: "画布"
        case .text: "文本"
        case .sticker: "贴纸"
        case .border: "边框"
        case .draw: "涂鸦"
        case .filter: "滤镜"
        case .frame: "帧"
        case .crop: "裁剪"
        }
    }

    var icon: String {
        switch self {
        case .asset: "photo.badge.plus"
        case .canvas: "rectangle.split.3x1"
        case .text: "textformat"
        case .sticker: "face.smiling"
        case .border: "square"
        case .draw: "paintbrush.pointed"
        case .filter: "camera.filters"
        case .frame: "square.grid.3x3"
        case .crop: "crop"
        }
    }
}

/// 编辑页（参考 ImgPlay 布局）
/// 自上而下：导航栏 → 画布（顶到最上面，位置固定） → 时间轴+播放按钮 → 底部工具栏+速度条
/// 工具（画布/文本/贴纸/帧等）点击弹出 sheet 遮住编辑页
struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAssetPicker = false
    @State private var showBackgroundPicker = false
    /// 工具 sheet（点击工具栏弹出，遮住编辑页）
    @State private var toolSheet: EditorTool?

    private let timer = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // ① 大画布（顶到最上面，占满剩余空间，位置固定）
            CanvasView()
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ② 时间轴 + 播放按钮（画布下方，拖动素材控制起点/终点）
            timelineArea
                .padding(.horizontal, 12)
                .padding(.top, 6)

            // ③ 底部：工具栏 + 速度条
            bottomArea
        }
        .magicBackground()
        .onReceive(timer) { _ in appState.tick() }
        .onAppear {
            appState.ensureComposition()
            appState.selectBackground()
        }
        .overlay(alignment: .top) {
            // 自定义顶部栏（浮在画布上方，不占布局空间）
            topBar
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $appState.showExportView) {
            ExportView().environmentObject(appState)
        }
        .sheet(isPresented: $showAssetPicker) {
            AssetPickerView().environmentObject(appState)
        }
        .sheet(isPresented: $showBackgroundPicker) {
            BackgroundPickerView().environmentObject(appState)
        }
        .sheet(item: $toolSheet) { tool in
            if tool == .frame {
                FrameGridView()
                    .environmentObject(appState)
                    .presentationDetents([.medium, .large])
            } else {
                NavigationStack {
                    toolPanel(tool)
                        .navigationTitle(tool.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .magicBackground()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { toolSheet = nil }
                                    .fontWeight(.semibold)
                                    .foregroundStyle(LF.gold)
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    /// 自定义顶部栏（编辑信息 + 保存，浮在画布上方）
    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("编辑")
                    .font(.subheadline.weight(.semibold))
                if let comp = appState.composition {
                    Text(frameInfoText(comp))
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                }
            }
            Spacer()
            Button { appState.showExportView = true } label: {
                Text("保存")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(LF.gold, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 帧信息

    private func frameInfoText(_ comp: Composition) -> String {
        let totalFrames = comp.duration.isFinite && comp.fps > 0
            ? max(Int(comp.duration * comp.fps), 1) : 0
        let duration = comp.duration.isFinite ? comp.duration : 0
        return "\(totalFrames)张 / \(String(format: "%.2f", duration))秒"
    }

    // MARK: - 时间轴区域（画布下方：播放按钮 + 双轨时间轴）

    private var timelineArea: some View {
        VStack(spacing: 4) {
            // 播放按钮行
            HStack(spacing: 10) {
                Button {
                    appState.isPlaying ? appState.pause() : appState.play()
                } label: {
                    Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.callout)
                        .frame(width: 30, height: 30)
                        .background(LF.gold, in: Circle())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                Text(String(format: "%.2f / %.2f s", appState.currentTime, appState.composition?.duration ?? 0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LF.textSecondary)
                Spacer()
            }
            // 双轨时间轴（元素轨 + 音频轨，可拖动起点/终点）
            TimelineView()
        }
    }

    // MARK: - 底部区域

    /// 有选中对象（元素/音频）时显示属性面板
    private var hasSelection: Bool {
        !appState.selectedElementIDs.isEmpty
            || appState.selectedAudioID != nil
    }

    private var bottomArea: some View {
        VStack(spacing: 4) {
            if hasSelection {
                // 选中状态：工具栏 + 属性面板（所有原有功能完整保留）
                editorToolbar
                    .padding(.horizontal, 4)

                ElementInspectorView()
                    .padding(.horizontal, 12)
                    .frame(maxHeight: 210)
            } else {
                // 默认：工具栏 + 速度条
                editorToolbar
                    .padding(.horizontal, 4)

                speedControl
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    // MARK: - 工具栏（ImgPlay 式：图标+文字，横排可滚动）

    private var editorToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(EditorTool.allCases) { tool in
                    Button {
                        handleToolTap(tool)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tool.icon)
                                .font(.title3)
                                .frame(width: 28, height: 28)
                            Text(tool.title)
                                .font(.caption2)
                        }
                        .foregroundStyle(LF.textPrimary)
                        .frame(width: 52)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func handleToolTap(_ tool: EditorTool) {
        switch tool {
        case .asset:
            showAssetPicker = true
        case .text:
            if let existing = appState.composition?.elements.first(where: {
                if case .text = $0.kind { return true }; return false
            }) {
                appState.selectElement(existing.id)
                toolSheet = .text
            } else {
                appState.addTextElement()
                toolSheet = .text
            }
        case .crop:
            appState.isCropping = true
        default:
            toolSheet = tool
        }
    }
    // MARK: - 速度条（兔子/滑块/乌龟 + 反转/循环）

    private var speedControl: some View {
        HStack(spacing: 8) {
            // 反转
            Button { appState.isReversed.toggle() } label: {
                Image(systemName: "arrow.right.arrow.left")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(appState.isReversed ? LF.gold.opacity(0.3) : .clear, in: Circle())
                    .foregroundStyle(appState.isReversed ? LF.gold : LF.textSecondary)
            }
            .buttonStyle(.plain)

            // 乌龟（慢，对应左侧低 fps）
            Image(systemName: "tortoise.fill")
                .font(.caption)
                .foregroundStyle(LF.gold)

            // 速度滑块（左慢右快：1~30 fps）
            Slider(
                value: Binding(
                    get: { appState.composition?.fps ?? 15 },
                    set: { appState.setPlaybackFPS($0) }
                ),
                in: 1...30,
                step: 1
            )
            .tint(LF.gold)

            // 兔子（快，对应右侧高 fps）
            Image(systemName: "hare.fill")
                .font(.caption)
                .foregroundStyle(LF.gold)

            // 循环
            Button { appState.isLooping.toggle() } label: {
                Image(systemName: appState.isLooping ? "repeat" : "repeat.1")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(appState.isLooping ? LF.gold.opacity(0.3) : .clear, in: Circle())
                    .foregroundStyle(appState.isLooping ? LF.gold : LF.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 工具面板（sheet 弹出，遮住编辑页）

    private func toolPanel(_ tool: EditorTool) -> some View {
        Group {
            switch tool {
            case .asset, .crop, .frame:
                EmptyView() // frame 走全屏 FrameGridView
            case .canvas:
                canvasPanel
            case .text:
                textPanel
            case .sticker:
                stickerPanel
            case .border:
                borderPanel
            case .draw:
                drawPanel
            case .filter:
                filterPanel
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - 各工具子面板（占位，后续填充完整内容）

    private var canvasPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                // 画布比例（横排）
                HStack(spacing: 8) {
                    Text("比例").font(.caption2).foregroundStyle(LF.textSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CanvasAspect.allCases) { aspect in
                                Button { appState.setCanvasAspect(aspect) } label: {
                                    VStack(spacing: 3) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(
                                                appState.composition?.canvasRect.size == aspect.canvasSize ? LF.gold : LF.surface2,
                                                lineWidth: appState.composition?.canvasRect.size == aspect.canvasSize ? 2 : 1
                                            )
                                            .frame(width: 36, height: 36)
                                        Text(aspect.title).font(.caption2)
                                    }
                                    .foregroundStyle(LF.textPrimary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                // 纯色背景（横排）
                HStack(spacing: 8) {
                    Text("背景").font(.caption2).foregroundStyle(LF.textSecondary)
                    ForEach(bgColors, id: \.hex) { color in
                        Button { appState.setBackground(color: color.hex) } label: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(hex: color.hex))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isBgColor(color.hex) ? LF.gold : LF.surface2, lineWidth: isBgColor(color.hex) ? 2.5 : 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        toolSheet = nil
                        showBackgroundPicker = true
                    } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                            .frame(width: 36, height: 36)
                            .overlay { Text("更多").font(.caption2).foregroundStyle(.white) }
                    }
                    .buttonStyle(.plain)
                }
                // 图案叠加（横排：类型+参数一行搞定）
                HStack(spacing: 8) {
                    Text("图案").font(.caption2).foregroundStyle(LF.textSecondary)
                    Button { appState.setBackgroundPattern(nil) } label: {
                        Text("无")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(bgOverlay == nil ? LF.gold : LF.surface2, in: Capsule())
                            .foregroundStyle(bgOverlay == nil ? .black : LF.textPrimary)
                    }
                    .buttonStyle(.plain)
                    ForEach(bgLinePatterns) { pattern in
                        Button {
                            var style = bgOverlay ?? BackgroundPatternStyle()
                            style.pattern = pattern
                            if pattern == .mosaic {
                                style.lineWidth = 48; style.spacing = 48; style.angle = 0
                            } else {
                                style.lineWidth = 4; style.spacing = 36; style.angle = 0
                            }
                            appState.setBackgroundPattern(style)
                        } label: {
                            Text(pattern.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(bgOverlay?.pattern == pattern ? LF.gold : LF.surface2, in: Capsule())
                                .foregroundStyle(bgOverlay?.pattern == pattern ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if bgOverlay != nil {
                    // 图案参数（一行横排：粗细 | 疏密 | 颜色 | 角度）
                    HStack(spacing: 10) {
                        ForEach(bgPatternOptions(bgOverlay?.pattern).widths, id: \.0) { opt in
                            Button {
                                var style = bgOverlay ?? BackgroundPatternStyle()
                                style.lineWidth = opt.1
                                appState.setBackgroundPattern(style)
                            } label: {
                                Text(opt.0)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(abs((bgOverlay?.lineWidth ?? 0) - opt.1) < 0.1 ? LF.gold : LF.surface2, in: Capsule())
                                    .foregroundStyle(abs((bgOverlay?.lineWidth ?? 0) - opt.1) < 0.1 ? .black : LF.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                        if bgOverlay?.pattern != .mosaic {
                            ForEach(bgPatternOptions(bgOverlay?.pattern).spacing, id: \.0) { opt in
                                Button {
                                    var style = bgOverlay ?? BackgroundPatternStyle()
                                    style.spacing = opt.1
                                    appState.setBackgroundPattern(style)
                                } label: {
                                    Text(opt.0)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(abs((bgOverlay?.spacing ?? 0) - opt.1) < 1 ? LF.gold : LF.surface2, in: Capsule())
                                        .foregroundStyle(abs((bgOverlay?.spacing ?? 0) - opt.1) < 1 ? .black : LF.textPrimary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach(bgPatternColors, id: \.hex) { color in
                            Button {
                                var style = bgOverlay ?? BackgroundPatternStyle()
                                style.colorHex = color.hex
                                appState.setBackgroundPattern(style)
                            } label: {
                                Circle().fill(Color(hex: color.hex))
                                    .frame(width: 22, height: 22)
                                    .overlay { Circle().stroke(bgOverlay?.colorHex == color.hex ? LF.gold : LF.surface2, lineWidth: bgOverlay?.colorHex == color.hex ? 2.5 : 1) }
                            }
                            .buttonStyle(.plain)
                        }
                        if bgOverlay?.pattern != .mosaic {
                            Text("角度").font(.caption2).foregroundStyle(LF.textSecondary)
                            Slider(
                                value: Binding(
                                    get: { bgOverlay?.angle ?? 0 },
                                    set: { var s = bgOverlay ?? BackgroundPatternStyle(); s.angle = $0; appState.setBackgroundPattern(s) }
                                ),
                                in: 0...180
                            )
                            .tint(LF.gold)
                            .frame(maxWidth: 140)
                            Text("\(Int(bgOverlay?.angle ?? 0))°").font(.caption2.monospacedDigit()).foregroundStyle(LF.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 背景面板（完整版：纯色+图案叠加+参数+更多）

    private let bgColors: [(name: String, hex: String)] = [
        ("白色", "FFFFFF"), ("微信背景色", "EDEDED"), ("黑色", "000000")
    ]
    private let bgPatternColors: [(name: String, hex: String)] = [
        ("白", "FFFFFF"), ("黑", "000000"), ("灰", "B8BDC9"), ("金", "E8C05C"),
        ("红", "E74C3C"), ("粉", "FF9FF3"), ("蓝", "54A0FF"),
        ("绿", "1DD1A1"), ("紫", "8B7CF6")
    ]
    private let bgLinePatterns: [BackgroundPattern] = [.horizontal, .mosaic]

    private var bgOverlay: BackgroundPatternStyle? {
        appState.composition?.background.patternOverlay
    }

    private func bgPatternOptions(_ pattern: BackgroundPattern?) -> (
        widths: [(String, CGFloat)], spacing: [(String, CGFloat)]
    ) {
        if pattern == .mosaic {
            return ([("小", 32), ("中", 48), ("大", 64)], [])
        }
        return ([("细", 2), ("中", 4), ("粗", 8)], [("疏", 48), ("中", 36), ("密", 24)])
    }

    private func isBgColor(_ hex: String) -> Bool {
        guard let bg = appState.composition?.background, case .solid = bg.kind else { return false }
        return bg.topColor == hex
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let element = appState.primarySelectedElement,
               case .text(let textID) = element.kind,
               let text = appState.composition?.texts.first(where: { $0.id.uuidString == textID }) {
                // 选中文字元素：内联编辑（内容/字号/颜色）
                TextField("输入文字", text: Binding(
                    get: { text.text },
                    set: { newValue in appState.updateText(text.id) { $0.text = newValue } }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)

                HStack(spacing: 10) {
                    Text("字号")
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                    Slider(
                        value: Binding(
                            get: { Double(text.fontSize) },
                            set: { newValue in appState.updateText(text.id) { $0.fontSize = CGFloat(newValue) } }
                        ),
                        in: 24...300
                    )
                    .tint(LF.gold)
                    Text("\(Int(text.fontSize))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                        .frame(width: 32, alignment: .trailing)
                }

                HStack(spacing: 10) {
                    ForEach(textPanelColors, id: \.hex) { color in
                        Button { appState.updateText(text.id) { $0.colorHex = color.hex } } label: {
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
            } else {
                Text("点击工具栏「文本」添加文字，选中文字后可编辑")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }
        }
    }

    private let textPanelColors: [(name: String, hex: String)] = [
        ("白", "FFFFFF"), ("黑", "000000"), ("金", "E8C05C"), ("红", "E74C3C"),
        ("粉", "FF9FF3"), ("蓝", "54A0FF"), ("绿", "1DD1A1"), ("紫", "8B7CF6")
    ]

    private var stickerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内置贴纸")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            Text("手绘风动画贴纸即将上线（蜡笔画、涂鸦等）")
                .font(.caption)
                .foregroundStyle(LF.textSecondary)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
        }
    }

    private var borderPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let element = appState.primarySelectedElement,
               case .clip(let clipID) = element.kind,
               let clip = appState.clips.first(where: { $0.id == clipID }) {
                // 风格选择（无/描边/自定义描边/漫画/平滑）
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
                                    .background(clip.stickerStyle == style ? LF.gold : LF.surface2, in: Capsule())
                                    .foregroundStyle(clip.stickerStyle == style ? .black : LF.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                // 自定义描边参数（粗细/颜色）
                if clip.stickerStyle == .customOutline {
                    HStack(spacing: 8) {
                        ForEach(EdgeThickness.allCases) { thickness in
                            Button { appState.setClipEdgeThickness(clip.id, thickness) } label: {
                                Text(thickness.title)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(clip.edgeThickness == thickness ? LF.gold : LF.surface2, in: Capsule())
                                    .foregroundStyle(clip.edgeThickness == thickness ? .black : LF.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("选中画布上的人物素材后可设置边框/描边风格")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }
        }
    }

    private var drawPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("涂鸦（开发中）")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            Text("画笔工具即将上线，支持在画布上手绘涂鸦")
                .font(.caption)
                .foregroundStyle(LF.textSecondary)
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("滤镜（选中元素后生效）")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ElementFilter.allCases) { filter in
                        Button {
                            if let id = appState.primarySelectedID {
                                appState.setElementFilter(id, filter == .none ? nil : filter)
                            }
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(LF.surface2)
                                    .frame(width: 52, height: 52)
                                    .overlay {
                                        Text(filter.title)
                                            .font(.caption2)
                                    }
                                    .overlay {
                                        if let element = appState.primarySelectedElement,
                                           (element.filter ?? .none) == filter {
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(LF.gold, lineWidth: 2)
                                        }
                                    }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
