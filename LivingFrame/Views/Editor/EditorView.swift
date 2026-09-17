import LivingFrameCore
import SwiftUI
import UIKit

/// 编辑器工具类型（参考 ImgPlay 底部工具栏）
enum EditorTool: String, CaseIterable, Identifiable {
    case timeline   // 时间轴（展开/收起）
    case collage     // 拼接（照片、动态照片和视频）
    case canvas      // 画布（比例 + 背景）
    case text        // 文本（添加/编辑文字）
    case sticker     // 贴纸（内置贴纸库）
    case border      // 边框（人物描边 + 画面外框）
    case draw        // 涂鸦（画笔）
    case filter      // 滤镜
    case frame       // 帧（帧选择/编辑）
    case crop        // 裁剪

    var id: String { rawValue }

    /// 文字工具统一使用无语言字符的系统图标，避免显示中文/英文文字本身。
    static let textIcon = "text.alignleft"

    var title: LocalizedStringKey {
        switch self {
        case .timeline: "时间轴"
        case .collage: "拼接"
        case .canvas: "画布"
        // 使用本地化 key：中文显示“文字”，英文等语言显示为“Text”。
        case .text: "文字"
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
        case .timeline: "timeline.selection"
        case .collage: "square.stack.3d.down.right"
        case .canvas: "rectangle.on.rectangle"
        case .text: Self.textIcon
        case .sticker: "face.smiling"
        case .border: "square"
        case .draw: "paintbrush.pointed"
        case .filter: "camera.filters"
        case .frame: "square.grid.3x3"
        case .crop: "crop"
        }
    }

    /// 当前版本只把已完成且属于核心编辑流程的工具放进主工具栏。
    /// 帧选择入口暂时隐藏；保留 EditorTool.frame、点击处理和 FrameGridView，后续可恢复。
    static let visibleCases: [EditorTool] = [.timeline, .collage, .canvas, .text, .sticker, .crop]
}

private struct CollageEditorRequest: Identifiable {
    let id = UUID()
    let elementIDs: [UUID]
}

/// 编辑页（参考 ImgPlay 布局）
/// 固定工作区：顶部信息 → 有层次的画布 → 播放控制 → 独立滚动时间轴 → 固定工具栏。
/// 页面本身不再纵向滚动，避免与时间轴轨道列表争抢同方向手势。
struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAssetPicker = false
    /// 双击已有背景元素时，直接复用拼接编辑器而不是进入通用检查器。
    @State private var collageEditorRequest: CollageEditorRequest?
    /// 长按贴纸后显示的动态预览。
    @State private var previewSticker: StickerDefinition?
    /// 贴纸面板当前选中的视觉分类。
    @State private var selectedStickerCategory: StickerCategory = .doodle
    /// 工具 sheet（点击工具栏弹出，遮住编辑页）
    @State private var toolSheet: EditorTool?
    /// 选中元素后的详细属性面板（不再常驻占用画布高度）
    @State private var showInspectorSheet = false
    /// 清空编辑页前的二次确认
    @State private var showClearConfirmation = false
    /// 删除画布选中素材前的二次确认
    @State private var showDeleteSelectionConfirmation = false
    /// 放弃当前作品草稿前的二次确认
    @State private var showDiscardDraftConfirmation = false
    /// 全屏预览（播放控制行最右侧按钮）
    @State private var showPreview = false
    /// 时间轴默认显示；用户收起后记住选择，避免每次进入编辑页都重复操作。
    @AppStorage("gifbloom.editor.showTimeline") private var showTimeline = true
    /// 作品名称平时作为紧凑标题展示，点击后使用独立 Sheet 编辑并管理键盘焦点。
    @State private var showRenameWorkEditor = false
    @State private var workNameDraft = ""

    var body: some View {
        GeometryReader { proxy in
            let workspaceWidth = max(proxy.size.width - 24, 1)
            let canvasSize = editorCanvasSize(
                in: proxy.size,
                timelineVisible: showTimeline,
                maxWidth: workspaceWidth
            )
            VStack(spacing: 0) {
                // ① 顶部工程信息固定，时间轴滚动不会推走它。
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                // ② 纵向工作区：画布 → 播放控制 → 时间轴，避免手机屏幕横向拥挤。
                VStack(spacing: 0) {
                    CanvasView {
                        requestInspectorForSelection()
                    }
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .overlay(alignment: .topTrailing) {
                            // 添加素材是编辑流程的高频入口，固定在画布右上角，避免用户
                            // 需要先寻找底部工具栏才能开始编辑。圆形按钮只保留图标，
                            // 半透明背景减少对画布内容的遮挡。
                            if !appState.isCropping {
                                Button {
                                    showAssetPicker = true
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                        .background(LF.accentGradient.opacity(0.78), in: Circle())
                                        .shadow(color: LF.header.opacity(0.22), radius: 8, y: 3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("添加素材")
                                .padding(8)
                                .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
                            }
                        }
                        .animation(.snappy(duration: 0.22), value: appState.isCropping)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)

                    // 播放控制贴着画布，不随时间轴内容滚动。
                    transportBar
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)

                    // 时间轴位于画布下方；轨道上下浏览只发生在时间轴内部。
                    if showTimeline {
                        timelineArea
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                            .frame(maxHeight: .infinity)
                            .layoutPriority(1)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .layoutPriority(1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        // ⑤ 固定的玻璃工具栏通过 safe-area inset 预留空间，不覆盖时间轴操作区。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            editorToolbar
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 6)
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
        .sheet(isPresented: $showRenameWorkEditor) {
            WorkNameEditorSheet(name: workNameDraft) { name in
                appState.renameCurrentComposition(to: name)
            }
        }
        .sheet(item: $collageEditorRequest) { request in
            CollageEditorView(
                existingElementIDs: request.elementIDs
            )
                .environmentObject(appState)
        }
        .sheet(isPresented: $showInspectorSheet) {
            NavigationStack {
                ElementInspectorView()
                    .lfNavigationTitle("调整")
                    .navigationBarTitleDisplayMode(.inline)
                    .magicBackground()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showInspectorSheet = false }
                                .fontWeight(.semibold)
                                .foregroundStyle(LF.actionPrimary)
                        }
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("收起键盘") {
                                dismissKeyboard()
                            }
                            .fontWeight(.semibold)
                        }
                    }
            }
            // 检查器覆盖时间轴下半部分，画布和播放控制仍可见；需要更多参数时可继续上拉。
            .presentationDetents([.fraction(0.46), .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(LF.background)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(LF.background, for: .navigationBar)
            // 检查器是精细编辑状态：暂停可冻结当前帧，避免播放时间持续变化
            // 让滑块、样式和源片段编辑看起来无法生效。
            .onAppear { appState.pause() }
        }
        .alert("清空编辑内容？", isPresented: $showClearConfirmation) {
            Button("清空", role: .destructive) {
                appState.clearEditorContent()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除画布和时间轴中的全部内容，但不会删除素材库里的素材。")
        }
        .alert("自动保存失败", isPresented: Binding(
            get: { appState.autosaveError != nil },
            set: { if !$0 { appState.dismissAutosaveError() } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(appState.autosaveError ?? "请稍后重试。")
        }
        .alert("保存失败", isPresented: Binding(
            get: { appState.saveError != nil },
            set: { if !$0 { appState.dismissSaveError() } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(appState.saveError ?? "请稍后重试。")
        }
        .confirmationDialog("放弃草稿？", isPresented: $showDiscardDraftConfirmation, titleVisibility: .visible) {
            Button("恢复正式版本", role: .destructive) {
                Task { await appState.discardCurrentDraft() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前作品下的草稿，并恢复到上次手动保存的版本。")
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
                        .lfNavigationTitle(tool.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .magicBackground()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { toolSheet = nil }
                                    .fontWeight(.semibold)
                                .foregroundStyle(LF.gold)
                            }
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("收起键盘") {
                                    dismissKeyboard()
                                }
                                .fontWeight(.semibold)
                            }
                        }
                }
                .presentationDetents(
                    tool == .canvas || tool == .text
                        ? [.height(420), .large]
                        : [.medium, .large]
                )
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(28)
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
            }
        }
    }

    /// 自定义顶部栏：左侧展示作品信息，右侧只保留导出。
    /// 导出时会自动生成正式作品；编辑过程中的变更仍由草稿自动保存承接。
    private var topBar: some View {
        HStack(spacing: 8) {
            if let comp = appState.composition {
                Button {
                    beginWorkNameEditing(comp.name)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(comp.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "pencil.line")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(LF.header)

                        HStack(spacing: 5) {
                            Text(frameInfoText(comp))
                                .lineLimit(1)
                            saveStatusView
                        }
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(String.localizedStringWithFormat(
                    NSLocalizedString("编辑作品名称，当前名称：%1$@", comment: "Edit work name accessibility label"),
                    comp.name as NSString
                ))
                .contextMenu {
                    if appState.currentWorkHasDraft {
                        Button {
                            showDiscardDraftConfirmation = true
                        } label: {
                            Label("恢复正式版", systemImage: "arrow.uturn.backward")
                        }
                    }
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("清空编辑内容", systemImage: "trash")
                    }
                }

                Button {
                    appState.showExportView = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LF.actionPrimary)
                        .frame(width: 42, height: 40)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(LF.selectionFill.opacity(0.42))
                                .allowsHitTesting(false)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(LF.actionPrimary.opacity(0.32), lineWidth: 1)
                        }
                }
                .buttonStyle(TopBarActionButtonStyle())
                .accessibilityLabel("导出")
            }
        }
        .padding(.horizontal, 4)
}

@ViewBuilder
private var saveStatusView: some View {
        if appState.isSavingWork {
            Text("保存中…")
                .foregroundStyle(LF.header)
        } else if appState.isAutosavingDraft {
            ProgressView()
                .controlSize(.mini)
            Text("草稿保存中…")
                .foregroundStyle(LF.header)
        } else if appState.hasUnsavedChanges {
            Text(appState.currentWorkHasDraft && !appState.hasPendingDraftAutosave ? "草稿已保存" : "未保存修改")
                .foregroundStyle(LF.header)
        } else if appState.editingWorkID != nil {
            Text("已保存")
                .foregroundStyle(LF.textSecondary)
        }
    }

    private func beginWorkNameEditing(_ name: String) {
        workNameDraft = name
        showRenameWorkEditor = true
    }

    // MARK: - 帧信息

    private func frameInfoText(_ comp: Composition) -> String {
        let totalFrames = comp.duration.isFinite && comp.fps > 0
            ? max(Int(comp.duration * comp.fps), 1) : 0
        let duration = comp.duration.isFinite ? comp.duration : 0
        return String.localizedStringWithFormat(
            NSLocalizedString("%1$lld 张 / %2$.2f 秒", comment: "Project frame and duration summary"),
            Int64(totalFrames), duration
        )
    }

    /// 根据时间轴状态计算画布尺寸：显示时为下方时间轴留出空间，隐藏时尽量放大画布。
    private func editorCanvasSize(
        in available: CGSize,
        timelineVisible: Bool,
        maxWidth: CGFloat
    ) -> CGSize {
        let aspect: CGFloat = {
            guard let rect = appState.composition?.renderRect, rect.height > 0 else { return 9 / 16 }
            return rect.width / rect.height
        }()
        let maximumHeight = timelineVisible
            ? min(max(190, available.height * 0.46), 420)
            : min(max(220, available.height - 150), 620)
        let width = min(max(1, maxWidth), maximumHeight * aspect)
        return CGSize(width: width, height: width / max(aspect, 0.01))
    }

    // MARK: - 时间轴区域（播放控制下方：双轨时间轴）

    private var timelineArea: some View {
        TimelineView(onRequestInspector: requestInspectorForSelection)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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

                    if hasSelectedItems {
                        Button {
                            showDeleteSelectionConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LF.destructive)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除当前选中素材")
                    }
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
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LF.textPrimary)
            .accessibilityLabel(appState.isPlaying ? "暂停" : "播放")
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .alert(deleteSelectionConfirmationTitle, isPresented: $showDeleteSelectionConfirmation) {
            Button("删除", role: .destructive) {
                deleteSelectedItems()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后，素材将从画布和时间轴中移除。")
        }
    }

    private func togglePlayback() {
        if appState.isPlaying {
            appState.pause()
            return
        }

        appState.play()
    }

    private var hasSelectedItems: Bool {
        !appState.selectedElementIDs.isEmpty || appState.selectedAudioID != nil
    }

    private var deleteSelectionConfirmationTitle: String {
        if appState.selectedElementIDs.count > 1 {
            return String.localizedStringWithFormat(
                NSLocalizedString("删除这 %1$lld 个素材？", comment: "Delete selected assets confirmation"),
                Int64(appState.selectedElementIDs.count)
            )
        }
        if appState.selectedAudioID != nil {
            return NSLocalizedString("删除这段音频？", comment: "Delete audio confirmation")
        }
        return NSLocalizedString("删除这个素材？", comment: "Delete asset confirmation")
    }

    private func deleteSelectedItems() {
        // 删除会同步改变选中集合，先复制快照，避免多选时漏删。
        let elementIDs = Array(appState.selectedElementIDs)
        let audioID = appState.selectedAudioID
        elementIDs.forEach(appState.deleteElement)
        if let audioID {
            appState.deleteAudio(audioID)
        }
    }

    // MARK: - 底部区域

    // MARK: - 工具栏（ImgPlay 式：图标+文字，横排可滚动）

    private var editorToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(EditorTool.visibleCases) { tool in
                    let isTimelineActive = tool == .timeline && showTimeline
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
                        .foregroundStyle(isTimelineActive ? LF.selectionStroke : LF.textPrimary)
                        .frame(width: 52)
                        .background(
                            isTimelineActive ? LF.selectionFill.opacity(0.78) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(tool == .timeline ? (showTimeline ? "已显示" : "已隐藏") : "")
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .padding(.horizontal, 10)
        }
        .frame(height: 70)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.68), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(0.09), radius: 16, y: 5)
    }

    private func handleToolTap(_ tool: EditorTool) {
        switch tool {
        case .timeline:
            withAnimation(.snappy(duration: 0.28)) {
                showTimeline.toggle()
            }
        case .collage:
            openCollageEditor()
        case .text:
            // 选中文字时打开当前文字；否则新增一个文字元素，支持叠加多段文字。
            if let selected = appState.primarySelectedElement,
               case .text = selected.kind {
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

    private func openCollageEditor() {
        guard let composition = appState.composition else {
            collageEditorRequest = CollageEditorRequest(elementIDs: [])
            return
        }

        let elementIDs: [UUID]
        if let selected = appState.primarySelectedElement,
           case .background = selected.kind {
            elementIDs = collageElementIDs(for: selected, in: composition)
        } else {
            // 拼接编辑器完成后保留当前素材选中状态；如果用户之后点了其它地方，
            // 仍优先恢复工程中已有的第一个拼接组，而不是重新打开空白画布。
            elementIDs = firstExistingCollageElementIDs(in: composition)
        }
        collageEditorRequest = CollageEditorRequest(elementIDs: elementIDs)
    }

    private func collageElementIDs(
        for element: CompositionElement,
        in composition: Composition
    ) -> [UUID] {
        guard case .background = element.kind else { return [] }
        if let groupID = element.collageGroupID {
            return composition.elements.compactMap { candidate in
                guard candidate.collageGroupID == groupID,
                      case .background = candidate.kind else { return nil }
                return candidate.id
            }
        }
        return [element.id]
    }

    private func firstExistingCollageElementIDs(in composition: Composition) -> [UUID] {
        guard let first = composition.elements.first(where: {
            if case .background = $0.kind { return true }
            return false
        }) else { return [] }
        return collageElementIDs(for: first, in: composition)
    }

    /// 打开当前选中元素的单素材检查器。
    ///
    /// 背景图片和剪影素材一样，时间轴上的调整入口只负责编辑当前实例；
    /// 分割线的整体布局仍通过底部“拼接”工具进入 CollageEditorView。
    private func requestInspectorForSelection() {
        appState.pause()
        showInspectorSheet = true
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
            case .timeline, .collage, .crop, .frame:
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
        .padding(.horizontal, tool == .canvas || tool == .text ? 0 : 16)
        .padding(.top, tool == .canvas || tool == .text ? 0 : 8)
    }

    // MARK: - 各工具子面板（占位，后续填充完整内容）

    private var canvasPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                EditorPanelHeader(
                    icon: "rectangle.on.rectangle",
                    title: "画布",
                    subtitle: "调整比例、画布背景和画面外缘"
                )
                canvasAppearanceEditor
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 背景面板（完整版：纯色+图案叠加+参数+更多）

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

    private var textPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                EditorPanelHeader(
                    icon: EditorTool.textIcon,
                    title: "文字",
                    subtitle: "输入内容并调整文字的视觉样式"
                )
                if let element = appState.primarySelectedElement,
                   case .text(let textID) = element.kind,
                   let text = appState.composition?.texts.first(where: { $0.id.uuidString == textID }) {
                    TextFormattingControls(text: text)
                        .environmentObject(appState)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: EditorTool.textIcon)
                            .font(.title2)
                            .foregroundStyle(LF.actionPrimary)
                        Text("画布上还没有选中的文字")
                            .font(.subheadline.weight(.semibold))
                        Text("点击工具栏「文字」添加一段文字")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(LF.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(LF.brandTint.opacity(0.28), lineWidth: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var stickerPanel: some View {
        let stickers = DecorationRenderer.stickerCatalog.filter { $0.category == selectedStickerCategory }

        return VStack(alignment: .leading, spacing: 8) {
            Text("贴纸分类")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StickerCategory.allCases, id: \.self) { category in
                        EditorOptionChip(
                            title: category.title,
                            isSelected: selectedStickerCategory == category
                        ) {
                            selectedStickerCategory = category
                        }
                    }
                }
            }
            Text("轻点添加，长按预览动画")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(stickers) { sticker in
                        StickerPickerCell(sticker: sticker) {
                            appState.addSticker(sticker.id)
                            toolSheet = nil
                        } onPreview: {
                            previewSticker = sticker
                        }
                    }
                }
            }
        }
        .sheet(item: $previewSticker) { sticker in
            StickerPreviewSheet(sticker: sticker) {
                appState.addSticker(sticker.id)
                previewSticker = nil
                toolSheet = nil
            }
            .environmentObject(appState)
        }
    }

    private var borderPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let element = appState.primarySelectedElement,
               case .clip(let clipID) = element.kind,
               let clip = appState.clips.first(where: { $0.id == clipID }),
               let composition = appState.composition {
                StickerStyleOptionPicker(
                    clip: clip,
                    element: element,
                    composition: composition,
                    currentTime: appState.currentTime,
                    selectedStyle: clip.stickerStyle
                ) { style in
                    appState.setClipStickerStyle(clip.id, style)
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
                }
            } else {
                Text("选中画布上的剪影素材后可设置边框/描边风格")
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
                        let isSelected = appState.primarySelectedElement.map { ($0.filter ?? .none) == filter } ?? false
                        Button {
                            if let id = appState.primarySelectedID {
                                appState.setElementFilter(id, filter == .none ? nil : filter)
                            }
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? LF.selectionFill : LF.surface2.opacity(0.42))
                                    .frame(width: 52, height: 52)
                                    .overlay {
                                        Text(filter.title)
                                            .font(.caption2)
                                            .foregroundStyle(isSelected ? LF.selectionText : LF.textPrimary)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(
                                                isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.16),
                                                lineWidth: isSelected ? 2 : 1
                                            )
                                    }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Compact feedback shared by the two high-frequency top-bar actions.
    private struct TopBarActionButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.84 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// 独立管理输入焦点，保存或取消时先释放键盘，再关闭编辑界面。
private struct WorkNameEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var name: String

    let onSave: (String) -> Void

    init(name: String, onSave: @escaping (String) -> Void) {
        _name = State(initialValue: name)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("作品名称")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)

                TextField("输入作品名称", text: $name)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(LF.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isNameFocused ? LF.selectionStroke : LF.header.opacity(0.18), lineWidth: 1)
                    }
                    .onSubmit(saveAndDismiss)

                Text("按键盘上的“完成”，或点击右上角保存。")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .lfNavigationTitle("修改名称")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancelAndDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: saveAndDismiss)
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成", action: saveAndDismiss)
                    .fontWeight(.semibold)
                    .disabled(trimmedName.isEmpty)
                }
            }
            .magicBackground()
        }
        .presentationDetents([.height(190)])
        .presentationDragIndicator(.visible)
        .onAppear {
            DispatchQueue.main.async {
                isNameFocused = true
            }
        }
        .onDisappear {
            isNameFocused = false
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveAndDismiss() {
        guard !trimmedName.isEmpty else { return }
        isNameFocused = false
        onSave(trimmedName)
        dismissAfterReleasingFocus()
    }

    private func cancelAndDismiss() {
        isNameFocused = false
        dismissAfterReleasingFocus()
    }

    private func dismissAfterReleasingFocus() {
        DispatchQueue.main.async {
            dismiss()
        }
    }
}

/// 工具面板的顶部说明：让用户先知道当前面板解决什么问题，再开始操作控件。
private struct EditorPanelHeader: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(LF.actionPrimary)
                .frame(width: 38, height: 38)
                .background(LF.selectionFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(LF.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }
}

/// 贴纸网格单元：轻点直接添加，长按打开动态预览。
private struct StickerPickerCell: View {
    let sticker: StickerDefinition
    let onSelect: () -> Void
    let onPreview: () -> Void

    @State private var isPressing = false

    var body: some View {
        VStack(spacing: 4) {
            StickerPreview(decorationID: sticker.id, frameDuration: sticker.frameDuration)
                .frame(width: 58, height: 58)
            Text(sticker.localizedName)
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(width: 84, height: 88)
        .background(isPressing ? LF.selectionFill : LF.surface2, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isPressing ? LF.selectionStroke : .clear, lineWidth: 2)
        }
        .foregroundStyle(LF.gold)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onSelect)
        .onLongPressGesture(
            minimumDuration: 0.45,
            maximumDistance: 12,
            pressing: { pressing in
                withAnimation(.easeOut(duration: 0.12)) {
                    isPressing = pressing
                }
            },
            perform: onPreview
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点添加，长按预览动画")
        .accessibilityAction(named: "预览") {
            onPreview()
        }
    }
}

/// 贴纸面板缩略图与长按预览共用同一套帧加载逻辑。
private struct StickerPreview: View {
    let decorationID: String
    let frameDuration: TimeInterval
    var isPlaying = false

    @State private var frames: [CGImage] = []
    @State private var frameIndex = 0

    var body: some View {
        Group {
            if !frames.isEmpty {
                Image(decorative: frames[min(frameIndex, frames.count - 1)], scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles")
                    .font(.title2)
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
            // 释放当前视图对帧数组的引用；解码缓存仍由 Core 层统一复用。
            frames.removeAll(keepingCapacity: false)
            frameIndex = 0
        }
        .task(id: "\(decorationID)-\(frames.count)-\(isPlaying)") {
            guard isPlaying, frames.count > 1 else { return }
            while !Task.isCancelled {
                let milliseconds = max(Int((frameDuration * 1000).rounded()), 1)
                try? await Task.sleep(for: .milliseconds(milliseconds))
                guard !Task.isCancelled, !frames.isEmpty else { return }
                frameIndex = (frameIndex + 1) % frames.count
            }
        }
    }
}

/// 长按贴纸预览弹窗：默认自动播放，也支持暂停/继续和直接添加。
private struct StickerPreviewSheet: View {
    let sticker: StickerDefinition
    let onAdd: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isPlaying = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LF.surface2.opacity(0.72))
                    StickerPreview(
                        decorationID: sticker.id,
                        frameDuration: sticker.frameDuration,
                        isPlaying: isPlaying
                    )
                        .padding(28)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)

                VStack(spacing: 5) {
                    Text(sticker.localizedName)
                        .font(.headline)
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("长按预览 · %1$lld 帧 · 约 %2$.1f 秒", comment: "Sticker preview duration"),
                        Int64(sticker.frameCount), sticker.defaultDuration
                    ))
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }

                HStack(spacing: 12) {
                    Button {
                        isPlaying.toggle()
                    } label: {
                        Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button("添加贴纸", action: onAdd)
                        .buttonStyle(.borderedProminent)
                        .tint(LF.actionPrimary)
                }
            }
            .padding(20)
            .lfNavigationTitle("贴纸预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .magicBackground()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
