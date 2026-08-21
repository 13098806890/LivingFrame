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

    var title: LocalizedStringKey {
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
        case .canvas: "rectangle.on.rectangle"
        case .text: "textformat"
        case .sticker: "face.smiling"
        case .border: "square"
        case .draw: "paintbrush.pointed"
        case .filter: "camera.filters"
        case .frame: "square.grid.3x3"
        case .crop: "crop"
        }
    }

    /// 当前版本只把已完成且属于核心编辑流程的工具放进主工具栏。
    static let visibleCases: [EditorTool] = [.asset, .canvas, .sticker, .border, .frame, .crop]
}

/// 编辑页（参考 ImgPlay 布局）
/// 自上而下：顶部信息 → 有层次的画布 → 播放控制 → 时间轴 → 紧凑工具栏
/// 工具和选中元素的详细属性通过 sheet 覆盖画布显示
struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAssetPicker = false
    /// 工具 sheet（点击工具栏弹出，遮住编辑页）
    @State private var toolSheet: EditorTool?
    /// 选中元素后的详细属性面板（不再常驻占用画布高度）
    @State private var showInspectorSheet = false
    /// 清空编辑页前的二次确认
    @State private var showClearConfirmation = false
    /// 全屏预览（播放控制行最右侧按钮）
    @State private var showPreview = false
    /// 主动保存作品的进行中/结果状态。
    @State private var isSavingWork = false
    @State private var workSaveResult: WorkSaveResult?

    var body: some View {
        ZStack(alignment: .bottom) {
            // 画布按屏幕宽度计算真实高度；竖屏比例较高时由外层滚动承载，
            // 不再为了给底部面板让空间而把画布缩窄。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // ① 顶部工程信息（参考 imgplay：标题和帧数居中）
                    topBar
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 8)

                    // ② 画布宽度始终铺满，比例只决定它的高度
                    CanvasView()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.clear)

                    // ③ 播放控制贴在画布下方
                    transportBar

                    // ④ 时间轴放在画布和播放控制之后，符合视频编辑器的操作顺序
                    timelineArea
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 6)
                }
                // 底部工具栏是覆盖层，滚动内容留出安全空间避免遮挡播放控制。
                .padding(.bottom, 74)
            }

            // ⑤ 底部只保留紧凑工具栏，详细编辑内容通过弹窗覆盖画布
            editorToolbar
        }
        .magicBackground()
        .onAppear {
            appState.ensureComposition()
            appState.selectBackground()
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $appState.showExportView) {
            ExportView().environmentObject(appState)
        }
        .sheet(isPresented: $showAssetPicker) {
            AssetPickerView().environmentObject(appState)
        }
        .sheet(isPresented: $showInspectorSheet) {
            NavigationStack {
                ElementInspectorView()
                    .navigationTitle("调整")
                    .navigationBarTitleDisplayMode(.inline)
                    .magicBackground()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("清空编辑内容？", isPresented: $showClearConfirmation) {
            Button("清空", role: .destructive) {
                appState.clearEditorContent()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除画布和时间轴中的全部内容，但不会删除素材库里的素材。")
        }
        .alert(item: $workSaveResult) { result in
            switch result {
            case .success(let updated):
                Alert(
                    title: Text(updated ? "作品已更新" : "作品已保存"),
                    message: Text("可以在“作品”页面继续编辑或删除。"),
                    dismissButton: .default(Text("好"))
                )
            case .failure:
                Alert(
                    title: Text("保存失败"),
                    message: Text("无法生成作品封面，请稍后再试。"),
                    dismissButton: .default(Text("好"))
                )
            }
        }
        .fullScreenCover(isPresented: $showPreview) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                CanvasView(drivesPlayback: false)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environmentObject(appState)
                Button {
                    showPreview = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
                .padding(.trailing, 14)
                .accessibilityLabel("关闭全屏预览")
            }
        }
        .sheet(item: $toolSheet) { tool in
            if tool == .frame {
                FrameGridView(
                    clipID: selectedFrameClipID,
                    editsComposition: appState.selectedBackground
                )
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
                .presentationDragIndicator(.visible)
            }
        }
    }

    /// 自定义顶部栏（编辑信息 + 主动保存/导出）
    private var topBar: some View {
        ZStack {
            VStack(spacing: 0) {
                Text("编辑")
                    .font(.subheadline.weight(.semibold))
                if let comp = appState.composition {
                    Text(frameInfoText(comp))
                        .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                }
            }

            HStack(spacing: 6) {
                Button {
                    showClearConfirmation = true
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(width: 54, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空编辑内容")

                Spacer()

                Button(action: saveWork) {
                    HStack(spacing: 3) {
                        if isSavingWork {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text("保存")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.textPrimary)
                    .frame(height: 30)
                    .padding(.horizontal, 7)
                    .background(LF.surface2.opacity(0.7), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSavingWork)
                .accessibilityLabel("保存作品")

                Button { appState.showExportView = true } label: {
                    Text("导出")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(LF.gold, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    private func saveWork() {
        guard !isSavingWork else { return }
        let isUpdating = appState.editingWorkID != nil
        isSavingWork = true
        Task { @MainActor in
            let saved = await appState.saveCurrentToWorks()
            isSavingWork = false
            workSaveResult = saved ? .success(updated: isUpdating) : .failure
        }
    }

    // MARK: - 帧信息

    private func frameInfoText(_ comp: Composition) -> String {
        let totalFrames = comp.duration.isFinite && comp.fps > 0
            ? max(Int(comp.duration * comp.fps), 1) : 0
        let duration = comp.duration.isFinite ? comp.duration : 0
        return "\(totalFrames)张 / \(String(format: "%.2f", duration))秒"
    }

    // MARK: - 时间轴区域（播放控制下方：双轨时间轴）

    private var timelineArea: some View {
        TimelineView()
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.65), lineWidth: 0.8)
            }
            .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 6)
    }

    private var transportBar: some View {
        ZStack {
            HStack {
                HStack(spacing: 4) {
                    Button {
                        appState.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appState.canUndo ? LF.textPrimary : LF.textSecondary.opacity(0.35))
                    .disabled(!appState.canUndo)
                    .accessibilityLabel("撤销")

                    Button {
                        appState.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appState.canRedo ? LF.textPrimary : LF.textSecondary.opacity(0.35))
                    .disabled(!appState.canRedo)
                    .accessibilityLabel("重做")
                }

                Spacer()

                Button {
                    showPreview = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LF.textPrimary)
                .accessibilityLabel("全屏预览")
            }

            Button {
                togglePlayback()
            } label: {
                Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LF.textPrimary)
            .accessibilityLabel(appState.isPlaying ? "暂停" : "播放")
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private func togglePlayback() {
        if appState.isPlaying {
            appState.pause()
            return
        }

        appState.play()
    }

    // MARK: - 底部区域

    /// 有选中对象（元素/音频）时显示属性面板
    private var hasSelection: Bool {
        !appState.selectedElementIDs.isEmpty
            || appState.selectedAudioID != nil
    }

    // MARK: - 工具栏（ImgPlay 式：图标+文字，横排可滚动）

    private var editorToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if hasSelection {
                    Button {
                        showInspectorSheet = true
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.title3)
                                .frame(width: 28, height: 28)
                            Text("调整")
                                .font(.caption2)
                        }
                        .foregroundStyle(LF.gold)
                        .frame(width: 52)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(EditorTool.visibleCases) { tool in
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
        .frame(height: 74)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.45))
                .frame(height: 0.8)
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

    /// 编辑帧优先作用于当前最后选中的素材元素；没有选中素材时保留原来的主素材回退行为。
    private var selectedFrameClipID: String? {
        guard let selectedID = appState.lastSelectedElementID,
              appState.selectedElementIDs.contains(selectedID),
              let element = appState.composition?.elements.first(where: { $0.id == selectedID }),
              case .clip(let clipID) = element.kind else {
            return nil
        }
        return clipID
    }

    // MARK: - 播放时钟（仅播放时运行）

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
                                            .fill(selectedCanvasBackgroundColor)
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(
                                                        appState.composition?.canvasRect.size == aspect.canvasSize ? LF.gold : LF.surface2,
                                                        lineWidth: appState.composition?.canvasRect.size == aspect.canvasSize ? 2 : 1
                                                    )
                                            }
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
                    ColorPicker(
                        "更多",
                        selection: Binding(
                            get: { selectedCanvasBackgroundColor },
                            set: { appState.setBackground(color: $0.hexRGB) }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: 36, height: 36)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                AngularGradient(
                                    colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                    center: .center
                                )
                            )
                            .overlay {
                                Text("更多")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.35), radius: 1)
                            }
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("更多背景颜色")
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
                    // 图案参数（粗细 | 疏密）
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
                    // 图案颜色
                    HStack(spacing: 10) {
                        ForEach(bgPatternColors, id: \.hex) { color in
                            Button {
                                var style = bgOverlay ?? BackgroundPatternStyle()
                                style.colorHex = color.hex
                                appState.setBackgroundPattern(style)
                            } label: {
                                Circle().fill(Color(hex: color.hex))
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
                    // 横线角度单独占下一行；马赛克不需要角度。
                    if bgOverlay?.pattern != .mosaic {
                        HStack(spacing: 10) {
                            Text("角度").font(.caption2).foregroundStyle(LF.textSecondary)
                            Slider(
                                value: Binding(
                                    get: { bgOverlay?.angle ?? 0 },
                                    set: { var s = bgOverlay ?? BackgroundPatternStyle(); s.angle = $0; appState.setBackgroundPattern(s) }
                                ),
                                in: 0...180
                            )
                            .tint(LF.gold)
                            .frame(maxWidth: .infinity)
                            Text("\(Int(bgOverlay?.angle ?? 0))°")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(LF.textSecondary)
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

    private var selectedCanvasBackgroundColor: Color {
        guard let background = appState.composition?.background else {
            return Color(hex: "FFFFFF")
        }
        return Color(hex: background.topColor)
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
        let doodleStickers = DecorationRenderer.stickerCatalog.filter { $0.category == .doodle }

        return VStack(alignment: .leading, spacing: 8) {
            Text("贴纸分类")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            HStack {
                Text("涂鸦")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(LF.gold, in: Capsule())
                    .foregroundStyle(.black)
                Spacer()
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(doodleStickers) { sticker in
                        Button {
                            appState.addSticker(sticker.id)
                            toolSheet = nil
                        } label: {
                            VStack(spacing: 4) {
                                AnimatedStickerPreview(decorationID: sticker.id)
                                    .frame(width: 58, height: 58)
                                Text(sticker.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(width: 84, height: 88)
                            .background(LF.surface2, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(LF.gold)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
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

private enum WorkSaveResult: Identifiable {
    case success(updated: Bool)
    case failure

    var id: String {
        switch self {
        case .success(let updated): updated ? "updated" : "created"
        case .failure: "failure"
        }
    }
}

/// 贴纸面板中的轻量循环预览：只创建一个 SwiftUI TimelineView，帧图像由 DecorationRenderer 缓存。
/// 视图离开面板后 TimelineView 自动停止刷新，异步加载任务也会被 SwiftUI 取消。
private struct AnimatedStickerPreview: View {
    let decorationID: String

    @State private var frames: [CGImage] = []
    @State private var animationStart = Date()

    var body: some View {
        Group {
            if frames.isEmpty {
                Image(systemName: "sparkles")
                    .font(.title2)
            } else {
                SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(animationStart))
                    let index = Int(elapsed / 0.1) % frames.count
                    Image(decorative: frames[index], scale: 1)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .task(id: decorationID) {
            let id = decorationID
            let loaded = await Task.detached(priority: .utility) {
                DecorationRenderer().previewFrames(for: id)
            }.value
            guard !Task.isCancelled else { return }
            frames = loaded
            animationStart = Date()
        }
        .onDisappear {
            // 释放当前视图对帧数组的引用；解码缓存仍由 Core 层统一复用。
            frames.removeAll(keepingCapacity: false)
        }
    }
}
