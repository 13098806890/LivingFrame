import Combine
import LivingFrameCore
import PhotosUI
import SwiftUI

/// 编辑页素材选择器：从素材库选择素材，或直接选择照片/动态素材进行拼接。
struct AssetPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// 从“拼接”进入时只展示照片/动态素材，不再让用户在提取和拼接之间二次判断。
    private let collageOnly: Bool
    @State private var selectedIDs: Set<String> = []
    @State private var selectedBackgroundIDs: Set<String> = []
    @State private var pickerMode: PickerMode = .person
    @State private var backgroundFilter: BackgroundFilter = .all
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isShowingBackgroundPicker = false
    @State private var isImportingBackground = false
    @State private var backgroundImportProgress: Double?
    @State private var backgroundImportCompletedCount = 0
    @State private var backgroundImportTotalCount = 0
    @State private var backgroundImportTask: Task<Void, Never>?
    @State private var isAddingSelectedAssets = false
    /// 当前浏览的文件夹（nil = 全部素材），按钮直接切换，不依赖 NavigationLink
    @State private var folderID: String?
    /// 拼接素材选完后交给独立拼接编辑器；普通剪影素材选择不需要这个回调。
    private let onCollageSelection: (([String]) -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    init(
        collageOnly: Bool = false,
        onCollageSelection: (([String]) -> Void)? = nil
    ) {
        self.collageOnly = collageOnly
        self.onCollageSelection = onCollageSelection
        _pickerMode = State(initialValue: collageOnly ? .background : .person)
    }

    private enum PickerMode: String, CaseIterable, Identifiable, Hashable {
        case person
        case background

        var id: String { rawValue }

        var title: String {
            switch self {
            case .person:
                NSLocalizedString("剪影素材", comment: "Cutout asset picker tab")
            case .background:
                NSLocalizedString("相册", comment: "Photo library picker tab")
            }
        }
    }

    private enum BackgroundFilter: String, CaseIterable, Identifiable {
        case all
        case still
        case animated

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .all: "全部素材"
            case .still: "静态"
            case .animated: "动态"
            }
        }
    }

    private var currentFolder: LibraryFolder? {
        appState.folders.first { $0.id == folderID }
    }

    /// 相册素材入口只展示最近导入的 20 项；作品引用的旧文件仍留在磁盘供工程使用。
    private var recentBackgroundMedia: [BackgroundMediaItem] {
        Array(appState.backgroundMedia.prefix(BackgroundStore.userMediaRetentionLimit))
    }

    /// Set 只负责去重；实际排版使用素材库顺序，保证同一批素材每次分区稳定。
    private var orderedSelectedBackgroundIDs: [String] {
        let ordered = recentBackgroundMedia
            .filter { selectedBackgroundIDs.contains($0.id) }
            .map(\.id)
        let known = Set(ordered)
        return ordered + selectedBackgroundIDs.filter { !known.contains($0) }
    }

    private var selectedAssetCount: Int {
        selectedIDs.count + selectedBackgroundIDs.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !collageOnly {
                        sourceTabs
                        if pickerMode == .person {
                            folderBar
                            if let folder = currentFolder, !appState.childFolders(of: folder.id).isEmpty {
                                childFolderBar(folder)
                            }
                            clipsGrid
                        } else {
                            backgroundGrid
                        }
                    } else {
                        backgroundGrid
                    }
                }
                .padding()
            }
            .lfNavigationTitle(collageOnly ? "拼接素材" : "添加素材")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .lfAnimatedPlainButtonStyle()
                    .accessibilityLabel("取消")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { @MainActor in
                            await addSelectedAssets()
                        }
                    } label: {
                        if isAddingSelectedAssets {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            let count = selectedAssetCount
                            Text(count == 0 ? NSLocalizedString("添加", comment: "Add") : String.localizedStringWithFormat(
                                NSLocalizedString("添加(%1$lld)", comment: "Add selected assets count"), Int64(count)
                            ))
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(
                        selectedAssetCount == 0 ||
                            isImportingBackground ||
                            isAddingSelectedAssets
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear {
            backgroundImportTask?.cancel()
        }
        .onChange(of: isShowingBackgroundPicker) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            Task { @MainActor in
                // Wait for PhotosPicker to publish the complete ordered selection
                // after its Done action, then reset the binding safely.
                await Task.yield()
                handleBackgroundSelection(photoItems)
            }
        }
    }

    private var sourceTabs: some View {
        Picker("素材来源", selection: $pickerMode) {
            ForEach(PickerMode.allCases) { mode in
                Text(verbatim: mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("asset-picker-source-tabs")
    }

    private func handleBackgroundSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems.removeAll()
        backgroundImportTask?.cancel()
        isImportingBackground = true
        backgroundImportProgress = 0
        backgroundImportCompletedCount = 0
        backgroundImportTotalCount = items.count
        backgroundImportTask = Task { @MainActor in
            for (index, item) in items.enumerated() {
                guard !Task.isCancelled else { break }
                let imported = await PhotoLibraryMediaImporter.loadBackgroundMedia(from: item) { progress in
                    Task { @MainActor in
                        guard backgroundImportTotalCount == items.count else { return }
                        let completed = Double(index) / Double(max(items.count, 1))
                        backgroundImportProgress = completed + progress / Double(max(items.count, 1))
                    }
                }
                if let imported,
                   let id = await appState.importBackgroundMedia(
                    data: imported.data,
                    preferredFileExtension: imported.fileExtension,
                    isVideo: imported.isVideo
                   ) {
                    selectedBackgroundIDs.insert(id)
                }
                backgroundImportCompletedCount = index + 1
                backgroundImportProgress = Double(index + 1) / Double(max(items.count, 1))
            }
            await appState.retainRecentBackgroundMedia(preserving: selectedBackgroundIDs)
            isImportingBackground = false
            backgroundImportTask = nil
        }
    }

    /// 将选择器中的素材真正创建为画布元素。
    /// 相册导入是异步的，先刷新一次媒体元数据，避免新导入的照片已经有 ID，
    /// 但 AppState 的 backgroundMedia 列表还没来得及更新，导致点击“添加”后画布没有元素。
    @MainActor
    private func addSelectedAssets() async {
        guard selectedAssetCount > 0,
              !isImportingBackground,
              !isAddingSelectedAssets else { return }

        isAddingSelectedAssets = true
        defer { isAddingSelectedAssets = false }

        if !orderedSelectedBackgroundIDs.isEmpty {
            await appState.reloadBackgroundMediaAndWait()
        }

        if let onCollageSelection {
            onCollageSelection(orderedSelectedBackgroundIDs)
        } else {
            for clip in appState.clips where selectedIDs.contains(clip.id) {
                appState.addElementFromClipID(clip.id)
            }
            for mediaID in orderedSelectedBackgroundIDs {
                appState.addBackgroundElement(mediaID: mediaID)
            }
        }
        dismiss()
    }

    /// 顶层：全部素材 + 根文件夹
    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                folderChip(title: "全部素材", id: nil)
                ForEach(appState.rootFolders()) { folder in
                    folderChip(title: folder.name, id: folder.id)
                }
            }
        }
    }

    /// 文件夹内的子文件夹（点击切换浏览）
    private func childFolderBar(_ folder: LibraryFolder) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(appState.childFolders(of: folder.id)) { child in
                    folderChip(title: child.name, id: child.id)
                }
            }
        }
    }

    private func folderChip(title: String, id: String?) -> some View {
        let isSelected = folderID == id
        return Button {
            folderID = id
            selectedIDs.removeAll()
        } label: {
            HStack(spacing: 6) {
                if id != nil {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(LF.folderIcon)
                }
                Text(title)
                    .lineLimit(1)
                if let id,
                   let folder = appState.folders.first(where: { $0.id == id }) {
                    Text("\(folder.clipIDs.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isSelected ? LF.folderIcon : LF.textSecondary)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LF.actionPrimary)
                        .accessibilityLabel("已选中")
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .contentShape(Capsule())
            .background(isSelected ? LF.selectionFill : LF.surface2.opacity(0.58), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected ? LF.selectionStroke : LF.brandTint.opacity(0.18),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .foregroundStyle(isSelected ? LF.selectionText : LF.textPrimary)
        }
        .lfAnimatedPlainButtonStyle()
    }

    private var scopedClips: [SegmentedClip] {
        guard let folderID else { return appState.clips }
        let ids = appState.clipIDs(includingChildrenOf: folderID)
        return appState.clips.filter { ids.contains($0.id) }
    }

    private var clipsGrid: some View {
        Group {
            if scopedClips.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "暂无素材",
                    message: "先在「素材库」生成剪影素材，\n再回到这里添加到画布"
                )
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(scopedClips) { clip in
                        AssetCell(clip: clip) {
                            if selectedIDs.contains(clip.id) {
                                selectedIDs.remove(clip.id)
                            } else {
                                selectedIDs.insert(clip.id)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: selectedIDs.contains(clip.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedIDs.contains(clip.id) ? LF.actionPrimary : LF.textSecondary.opacity(0.5))
                                .padding(6)
                                .allowsHitTesting(false)
                        }
                        .contextMenu {
                            if clip.loadAudioURL() != nil {
                                Button {
                                    appState.addAudioClip(from: clip)
                                } label: {
                                    Label("添加到音轨", systemImage: "waveform")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var backgroundGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择照片、动态照片或视频，系统会自动排版到画布中。")
                .font(.subheadline)
                .foregroundStyle(LF.textSecondary)

            Button {
                isShowingBackgroundPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title2)
                        .foregroundStyle(LF.header)
                        .frame(width: 42, height: 42)
                        .background(LF.selectionFill, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("从相册选择")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LF.textPrimary)
                        Text("一次最多选择 4 个，可继续分批添加")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .foregroundStyle(LF.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LF.surface2, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                    .stroke(LF.header.opacity(0.35), lineWidth: 1)
                }
            }
            .lfAnimatedPlainButtonStyle()
            .photosPicker(
                isPresented: $isShowingBackgroundPicker,
                selection: $photoItems,
                // 自动排版最多使用四个分区；之后仍可继续分批添加。
                maxSelectionCount: 4,
                selectionBehavior: .ordered,
                matching: .any(of: [.images, .livePhotos, .videos]),
                preferredItemEncoding: .current
            )
            .disabled(isImportingBackground)

            if isImportingBackground {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在导入素材")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(backgroundImportCompletedCount)/\(backgroundImportTotalCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(LF.textSecondary)
                    }
                    if let backgroundImportProgress {
                        ProgressView(value: backgroundImportProgress)
                        .tint(LF.header)
                    } else {
                        ProgressView()
                        .tint(LF.header)
                    }
                }
                .padding(12)
                .background(LF.selectionFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BackgroundFilter.allCases) { filter in
                        Button {
                            backgroundFilter = filter
                            selectedBackgroundIDs.removeAll()
                        } label: {
                            Text(filter.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background(
                                    backgroundFilter == filter ? LF.header : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(backgroundFilter == filter ? .white : LF.textPrimary)
                        }
                        .lfAnimatedPlainButtonStyle()
                    }
                }
            }

            let media = recentBackgroundMedia.filter { item in
                switch backgroundFilter {
                case .all: true
                case .still: !item.isAnimated
                case .animated: item.isAnimated
                }
            }
            if media.isEmpty {
                EmptyStateView(
                    icon: "photo.on.rectangle.angled",
                    title: "暂无拼接素材",
                    message: "点击上方按钮从相册导入照片、动态照片或视频"
                )
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(media) { item in
                        BackgroundAssetCell(
                            item: item,
                            isSelected: selectedBackgroundIDs.contains(item.id)
                        ) {
                            if selectedBackgroundIDs.contains(item.id) {
                                selectedBackgroundIDs.remove(item.id)
                            } else if selectedBackgroundIDs.count < 4 {
                                selectedBackgroundIDs.insert(item.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 动态素材预览：默认停在第一帧，由素材卡片传入播放状态并按素材帧率播放一次。
/// 播放按钮放在卡片外层，避免预览内容被裁切时一起消失。
struct AnimatedClipPreview: View {
    let clip: SegmentedClip
    let maxPixelSize: CGFloat
    private let usesCoreStickerStylePreview: Bool
    private let coreStickerStyleComposition: Composition?
    @Binding var isPlaying: Bool
    @Binding var isPreparingPlayback: Bool
    @State private var framePosition = 0
    /// 播放窗口内已经解码的小尺寸帧；不再一次性持有整段素材。
    @State private var decodedFrames: [Int: CGImage] = [:]
    /// Detail 预览播放窗口内已经套用贴纸效果的帧，与编辑器渲染管线保持一致。
    @State private var renderedStickerFrames: [Int: CGImage] = [:]

    private let initialPreloadCount = 6
    private let playbackPreloadWindow = 10
    init(
        clip: SegmentedClip,
        maxPixelSize: CGFloat,
        isPlaying: Binding<Bool>,
        isPreparingPlayback: Binding<Bool> = .constant(false),
        usesCoreStickerStylePreview: Bool = false,
        coreStickerStyleComposition: Composition? = nil
    ) {
        self.clip = clip
        self.maxPixelSize = maxPixelSize
        self.usesCoreStickerStylePreview = usesCoreStickerStylePreview
        self.coreStickerStyleComposition = coreStickerStyleComposition
        _isPlaying = isPlaying
        _isPreparingPlayback = isPreparingPlayback
    }

    private var playbackFrames: [Int] {
        clip.playbackFrameIndices
    }

    private var previewFrame: Int {
        guard !playbackFrames.isEmpty else { return 0 }
        return playbackFrames[min(framePosition, playbackFrames.count - 1)]
    }

    private var isDynamic: Bool {
        // 播放按钮应根据素材实际帧数显示；activeFrameIndices 可能因为帧编辑被暂时筛成 1 帧，
        // 不能用它来判断素材本身是不是动态素材。
        clip.frameCount > 1
    }

    private var decodedFrame: CGImage? {
        decodedFrames[framePosition]
    }

    private var usesRenderedStickerPreview: Bool {
        usesCoreStickerStylePreview && clip.stickerStyle != .none && coreStickerStyleComposition != nil
    }

    var body: some View {
        ZStack {
            CheckerboardView()
            if usesRenderedStickerPreview {
                if let renderedFrame = renderedStickerFrames[framePosition] {
                    Image(decorative: renderedFrame, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if let coreStickerStyleComposition {
                    CoreStickerStylePreviewFrame(
                        clip: clip,
                        frameIndex: previewFrame,
                        maxPixelSize: maxPixelSize,
                        composition: coreStickerStyleComposition
                    )
                } else {
                    ClipThumbnailView(clip: clip, index: previewFrame, maxPixelSize: maxPixelSize)
                }
            } else if let decodedFrame {
                ClipPreviewImage(image: decodedFrame, clip: clip)
            } else {
                ClipThumbnailView(clip: clip, index: previewFrame, maxPixelSize: maxPixelSize)
            }
            if isPreparingPlayback {
                ClipPreviewLoadingIndicator()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(
            .timingCurve(0.23, 1, 0.32, 1, duration: 0.18),
            value: isPreparingPlayback
        )
        .task(id: "\(isPlaying)-\(clip.cropCacheKey)-\(clip.stickerStyle.rawValue)") {
            await playOnceIfNeeded()
        }
        .onAppear {
        }
        .onDisappear {
            // 离开滚动区域时取消播放任务，避免不可见素材继续解码和刷新。
            isPlaying = false
            isPreparingPlayback = false
            decodedFrames.removeAll(keepingCapacity: false)
            renderedStickerFrames.removeAll(keepingCapacity: false)
        }
        .onChange(of: clip.id) { _, _ in
            framePosition = 0
            isPlaying = false
            isPreparingPlayback = false
            decodedFrames.removeAll(keepingCapacity: false)
            renderedStickerFrames.removeAll(keepingCapacity: false)
        }
        .onChange(of: clip.cropCacheKey) { _, _ in
            framePosition = 0
            isPreparingPlayback = false
            decodedFrames.removeAll(keepingCapacity: false)
            renderedStickerFrames.removeAll(keepingCapacity: false)
        }
        .onChange(of: clip.stickerStyle) { _, _ in
            framePosition = 0
            isPreparingPlayback = false
            renderedStickerFrames.removeAll(keepingCapacity: false)
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing {
                framePosition = 0
                isPreparingPlayback = false
            }
        }
    }

    private func playOnceIfNeeded() async {
        guard isPlaying, isDynamic else {
            isPreparingPlayback = false
            return
        }
        let preparationStartedAt = Date()
        framePosition = 0
        isPreparingPlayback = true
        decodedFrames.removeAll(keepingCapacity: true)
        renderedStickerFrames.removeAll(keepingCapacity: true)

        let indices = playbackFrames
        let clipValue = clip
        let usesStyledRenderer = usesRenderedStickerPreview
        // 带效果的播放也使用静态预览的尺寸；低分辨率帧在详情页放大后会模糊。
        let pixelSize = maxPixelSize
        let compositionValue = coreStickerStyleComposition

        if usesStyledRenderer, let compositionValue {
            // 样式效果每帧都包含形态学膨胀、阴影和模糊。使用有限窗口预取，
            // 让播放阶段只做 CGImage 切换，同时避免长视频一次持有整段帧的内存。
            let initialPositions = Array(0..<min(initialPreloadCount, indices.count))
            var prefetchTask: Task<[Int: CGImage], Never>?
            var nextPrefetchStart = initialPositions.count
            let preloadWindow = playbackPreloadWindow
            let preloadLead = max(preloadWindow / 2, 1)
            defer { prefetchTask?.cancel() }

            renderedStickerFrames = await Self.loadRenderedStickerFrames(
                initialPositions,
                clip: clipValue,
                composition: compositionValue,
                maxPixelSize: pixelSize
            )
            guard !Task.isCancelled, isPlaying, renderedStickerFrames.count > 1 else {
                isPreparingPlayback = false
                return
            }

            let remainingIndicatorDuration = 0.16 - Date().timeIntervalSince(preparationStartedAt)
            if remainingIndicatorDuration > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(remainingIndicatorDuration * 1_000_000_000))
                } catch {
                    isPreparingPlayback = false
                    return
                }
                guard !Task.isCancelled, isPlaying else {
                    isPreparingPlayback = false
                    return
                }
            }
            isPreparingPlayback = false

            let frameInterval = max(1.0 / max(clip.fps, 1), 0.04)
            for nextPosition in 0..<indices.count {
                guard !Task.isCancelled, isPlaying else { return }

                if renderedStickerFrames[nextPosition] == nil {
                    if let task = prefetchTask {
                        let loaded = await task.value
                        renderedStickerFrames.merge(loaded) { _, new in new }
                        prefetchTask = nil
                    }
                    if renderedStickerFrames[nextPosition] == nil {
                        let loaded = await Self.loadRenderedStickerFrames(
                            [nextPosition],
                            clip: clipValue,
                            composition: compositionValue,
                            maxPixelSize: pixelSize
                        )
                        renderedStickerFrames.merge(loaded) { _, new in new }
                    }
                }

                guard renderedStickerFrames[nextPosition] != nil else { continue }
                framePosition = nextPosition

                if prefetchTask == nil,
                   nextPrefetchStart < indices.count,
                   nextPosition + preloadLead >= nextPrefetchStart {
                    let end = min(nextPrefetchStart + preloadWindow, indices.count)
                    let window = Array(nextPrefetchStart..<end)
                    nextPrefetchStart = end
                    prefetchTask = Task.detached(priority: .userInitiated) {
                        await Self.loadRenderedStickerFrames(
                            window,
                            clip: clipValue,
                            composition: compositionValue,
                            maxPixelSize: pixelSize
                        )
                    }
                }

                do {
                    try await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
                } catch {
                    return
                }

                let minimumRetainedPosition = max(nextPosition - 2, 0)
                let maximumRetainedPosition = min(nextPosition + preloadWindow, indices.count - 1)
                renderedStickerFrames = renderedStickerFrames.filter { position, _ in
                    (minimumRetainedPosition...maximumRetainedPosition).contains(position)
                }
            }
            guard !Task.isCancelled else { return }
            isPlaying = false
            framePosition = 0
            return
        }

        let initialPositions = Array(0..<min(initialPreloadCount, indices.count))
        var prefetchTask: Task<[Int: CGImage], Never>?
        var nextPrefetchStart = initialPositions.count
        let preloadWindow = playbackPreloadWindow
        let preloadLead = max(preloadWindow / 2, 1)
        defer { prefetchTask?.cancel() }

        decodedFrames = await loadPreviewFrames(
            initialPositions,
            clip: clipValue,
            maxPixelSize: pixelSize
        )
        guard !Task.isCancelled, isPlaying else {
            isPreparingPlayback = false
            return
        }

        let minimumIndicatorDuration: TimeInterval = 0.16
        let remainingIndicatorDuration = minimumIndicatorDuration - Date().timeIntervalSince(preparationStartedAt)
        if remainingIndicatorDuration > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(remainingIndicatorDuration * 1_000_000_000))
            } catch {
                isPreparingPlayback = false
                return
            }
            guard !Task.isCancelled, isPlaying else {
                isPreparingPlayback = false
                return
            }
        }
        isPreparingPlayback = false

        let loadedFrameCount = decodedFrames.count
        guard indices.count > 1, loadedFrameCount > 1 else {
            isPlaying = false
            framePosition = 0
            return
        }

        let frameInterval = max(1.0 / max(clip.fps, 1), 0.04)
        for nextPosition in 0..<indices.count {
            guard !Task.isCancelled, isPlaying else { return }

            if decodedFrames[nextPosition] == nil {
                if let task = prefetchTask {
                    let loaded = await task.value
                    decodedFrames.merge(loaded) { _, new in new }
                    prefetchTask = nil
                }
                if decodedFrames[nextPosition] == nil {
                    let loaded = await loadPreviewFrames(
                        [nextPosition],
                        clip: clipValue,
                        maxPixelSize: pixelSize
                    )
                    decodedFrames.merge(loaded) { _, new in new }
                }
            }

            guard decodedFrames[nextPosition] != nil else { continue }
            framePosition = nextPosition

            if prefetchTask == nil,
               nextPrefetchStart < indices.count,
               nextPosition + preloadLead >= nextPrefetchStart {
                let end = min(nextPrefetchStart + preloadWindow, indices.count)
                let window = Array(nextPrefetchStart..<end)
                nextPrefetchStart = end
                prefetchTask = Task.detached(priority: .userInitiated) {
                    var loaded: [Int: CGImage] = [:]
                    for position in window {
                        guard !Task.isCancelled,
                              indices.indices.contains(position) else { continue }
                        if let image = FrameCache.shared.cachedThumbnail(
                            for: clipValue,
                            index: indices[position],
                            maxPixelSize: pixelSize
                        ) {
                            loaded[position] = image
                        }
                    }
                    return loaded
                }
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
            } catch {
                return
            }

            // 只保留当前播放点附近的窗口，避免缩略图缓存和组件状态重复持有整段素材。
            let minimumRetainedPosition = max(nextPosition - 2, 0)
            let maximumRetainedPosition = min(nextPosition + preloadWindow, indices.count - 1)
            decodedFrames = decodedFrames.filter { position, _ in
                (minimumRetainedPosition...maximumRetainedPosition).contains(position)
            }
        }

        guard !Task.isCancelled else { return }
        isPlaying = false
        framePosition = 0
    }

    private func loadPreviewFrames(
        _ positions: [Int],
        clip: SegmentedClip,
        maxPixelSize: CGFloat
    ) async -> [Int: CGImage] {
        let sourceIndices = clip.playbackFrameIndices
        return await Task.detached(priority: .userInitiated) {
            var loaded: [Int: CGImage] = [:]
            for position in positions {
                guard !Task.isCancelled,
                      sourceIndices.indices.contains(position),
                      let image = FrameCache.shared.cachedThumbnail(
                          for: clip,
                          index: sourceIndices[position],
                          maxPixelSize: maxPixelSize
                      ) else { continue }
                loaded[position] = image
            }
            return loaded
        }.value
    }

    private static func loadRenderedStickerFrames(
        _ positions: [Int],
        clip: SegmentedClip,
        composition: Composition,
        maxPixelSize: CGFloat
    ) async -> [Int: CGImage] {
        let sourceIndices = clip.playbackFrameIndices
        let renderTask = Task.detached(priority: .userInitiated) {
            let fps = max(clip.fps, 1)
            var rendered: [Int: CGImage] = [:]
            rendered.reserveCapacity(positions.count)
            let batchSize = 4
            for batchStart in stride(from: 0, to: positions.count, by: batchSize) {
                guard !Task.isCancelled else { break }
                let batchEnd = min(batchStart + batchSize, positions.count)
                let batch = Array(positions[batchStart..<batchEnd])
                let images = await withTaskGroup(
                    of: (Int, CGImage?).self,
                    returning: [(Int, CGImage?)].self
                ) { group in
                    for position in batch {
                        group.addTask {
                            guard !Task.isCancelled,
                                  sourceIndices.indices.contains(position) else {
                                return (position, nil)
                            }
                            let renderer = CompositionRenderer(frameMaxPixelSize: maxPixelSize)
                            let image = await renderer.renderAsync(
                                composition,
                                at: Double(sourceIndices[position]) / fps
                            )
                            return (position, image)
                        }
                    }

                    var results: [(Int, CGImage?)] = []
                    results.reserveCapacity(batch.count)
                    for await result in group {
                        results.append(result)
                    }
                    return results
                }
                for (position, image) in images {
                    if let image { rendered[position] = image }
                }
            }
            return rendered
        }
        return await withTaskCancellationHandler(operation: {
            await renderTask.value
        }, onCancel: {
            renderTask.cancel()
        })
    }
}

/// 素材缩略图正在准备播放帧时的明确反馈。
struct ClipPreviewLoadingIndicator: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(.white)
            .padding(9)
            .background(.black.opacity(0.56), in: Circle())
            .accessibilityLabel(NSLocalizedString(
                "准备中…",
                comment: "Clip preview preparation accessibility label"
            ))
    }
}

/// 素材卡片角落的轻量徽标。播放与音频入口共用尺寸和底色，保证左右对齐。
struct ClipPreviewBadgeIcon: View {
    let systemName: String
    var foregroundStyle: Color = .white
    var backgroundStyle: Color = .black.opacity(0.34)

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foregroundStyle.opacity(0.9))
            .frame(width: 26, height: 26)
            .background(backgroundStyle, in: Circle())
    }
}

/// 与音频徽标处于同一素材卡片覆盖层，确保不会被预览内容的裁切层隐藏。
struct ClipPreviewPlayButton: View {
    let clip: SegmentedClip
    @Binding var isPlaying: Bool
    @Binding var isPreparingPlayback: Bool

    init(
        clip: SegmentedClip,
        isPlaying: Binding<Bool>,
        isPreparingPlayback: Binding<Bool> = .constant(false)
    ) {
        self.clip = clip
        _isPlaying = isPlaying
        _isPreparingPlayback = isPreparingPlayback
    }

    var body: some View {
        if clip.frameCount > 1 {
            // 预览卡片外层可能还有“打开详情/选择素材”的 tap gesture。
            // 使用高优先级手势让左下角播放入口始终优先响应，不再被外层点击抢走。
            Group {
                if isPreparingPlayback {
                    ClipPreviewLoadingIndicator()
                } else {
                    ClipPreviewBadgeIcon(
                        systemName: isPlaying ? "pause.fill" : "play.fill"
                    )
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    isPlaying.toggle()
                }
            )
            .zIndex(2)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                isPlaying.toggle()
            }
            .accessibilityLabel(NSLocalizedString(
                isPreparingPlayback ? "准备中…" : (isPlaying ? "暂停动态素材" : "播放动态素材"),
                comment: "Animated media playback state"
            ))
        }
    }
}

/// 单帧缩略图在后台解码，避免素材网格和时间轴首次出现时阻塞主线程。
/// 动态素材的播放状态由 AnimatedClipPreview 管理，避免所有素材格同时启动计时器。
struct ClipThumbnailView: View {
    let clip: SegmentedClip
    let index: Int
    let maxPixelSize: CGFloat
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                ClipPreviewImage(image: image, clip: clip)
            } else {
                Color.black.opacity(0.25)
            }
        }
        .task(id: "\(clip.id)-\(index)-\(Int(maxPixelSize))-\(clip.cropCacheKey)") {
            let clipValue = clip
            let indexValue = index
            let maxPixelSizeValue = maxPixelSize
            let loaded = await Task.detached(priority: .utility) {
                FrameCache.shared.cachedThumbnail(
                    for: clipValue, index: indexValue, maxPixelSize: maxPixelSizeValue
                )
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// Detail 预览使用与编辑器和风格缩略图相同的 Core Image 渲染管线，
/// 保证漫画白边、描边留白和导出结果在大预览中保持一致。
private struct CoreStickerStylePreviewFrame: View {
    let clip: SegmentedClip
    let frameIndex: Int
    let maxPixelSize: CGFloat
    let composition: Composition
    @State private var renderedImage: CGImage?

    var body: some View {
        Group {
            if let renderedImage {
                Image(decorative: renderedImage, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ClipThumbnailView(
                    clip: clip,
                    index: frameIndex,
                    maxPixelSize: maxPixelSize
                )
            }
        }
        .task(id: renderKey) {
            let clipValue = clip
            let frameIndexValue = frameIndex
            let pixelSize = maxPixelSize
            let compositionValue = composition
            let rendered = await Task.detached(priority: .userInitiated) {
                let fps = max(clipValue.fps, 1)
                return await CompositionRenderer(frameMaxPixelSize: pixelSize).renderAsync(
                    compositionValue,
                    at: Double(frameIndexValue) / fps
                )
            }.value
            guard !Task.isCancelled else { return }
            renderedImage = rendered
        }
    }

    private var renderKey: String {
        [
            clip.id,
            String(frameIndex),
            clip.cropCacheKey,
            clip.stickerStyle.rawValue,
            clip.edgeStyle.rawValue,
            clip.edgeThickness.rawValue,
            clip.edgeColorHex,
            String(clip.normalizedRotationQuarterTurns),
            String(Int(maxPixelSize.rounded()))
        ].joined(separator: "|")
    }
}

/// 在素材库和编辑页缩略图中复现已保存的边缘与贴纸效果。
/// 导出仍使用 CompositionRenderer 的完整算法；这里使用透明帧的柔化轮廓，
/// 让用户在浏览素材时能一眼看出素材是否已经设置过描边/漫画/柔光/投影。
/// 模板渲染必须基于 alpha 着色，不能用 colorMultiply(.white)，否则白色轮廓
/// 会继续保留源图颜色，在 Convert 详情页的大预览中看起来像没有效果。
struct ClipPreviewImage: View {
    let image: CGImage
    let clip: SegmentedClip

    private var outlineColor: Color {
        Color(hex: clip.edgeColorHex)
    }

    private var haloRadius: CGFloat {
        max(3, min(clip.edgeThickness.radius / 6, 16))
    }

    private var stickerHaloRadius: CGFloat {
        max(3, min(clip.edgeThickness.radius / 5, 18))
    }

    var body: some View {
        ZStack {
            switch clip.edgeStyle {
            case .outline:
                halo(color: outlineColor, radius: haloRadius, opacity: 0.95)
            case .comic:
                halo(color: .black, radius: haloRadius + 4, opacity: 0.95)
                halo(color: .white, radius: max(2, haloRadius - 1), opacity: 0.95)
            case .glow:
                halo(color: LF.gold, radius: haloRadius + 4, opacity: 0.72)
            case .shadow:
                halo(color: .black, radius: max(2, haloRadius - 1), opacity: 0.55)
                    .offset(x: 3, y: 4)
            case .none:
                EmptyView()
            }

            switch clip.stickerStyle {
            case .outline:
                halo(color: .white, radius: stickerHaloRadius, opacity: 0.95)
            case .comic:
                halo(color: .black, radius: stickerHaloRadius * 1.55, opacity: 0.13)
                    .offset(y: 1)
                halo(color: .white, radius: stickerHaloRadius * 1.35, opacity: 0.98)
            case .smooth:
                halo(color: .white, radius: max(2, stickerHaloRadius * 0.55), opacity: 0.25)
            case .none:
                EmptyView()
            }

            baseImage()
        }
    }

    private func halo(color: Color, radius: CGFloat, opacity: Double) -> some View {
        baseImage(tint: color)
            .blur(radius: radius)
            .opacity(opacity)
    }

    private func baseImage(tint: Color? = nil) -> some View {
        GeometryReader { proxy in
            let normalizedTurns = clip.normalizedRotationQuarterTurns
            let isQuarterTurn = normalizedTurns % 2 == 1
            let imageSize = CGSize(
                width: isQuarterTurn ? proxy.size.height : proxy.size.width,
                height: isQuarterTurn ? proxy.size.width : proxy.size.height
            )
            let imageView = Image(decorative: image, scale: 1)
                .renderingMode(tint == nil ? .original : .template)
                .resizable()
                .scaledToFill()

            Group {
                if let tint {
                    imageView.foregroundStyle(tint)
                } else {
                    imageView
                }
            }
            .frame(width: imageSize.width, height: imageSize.height)
            .rotationEffect(.degrees(clip.continuousRotationDegrees))
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}
