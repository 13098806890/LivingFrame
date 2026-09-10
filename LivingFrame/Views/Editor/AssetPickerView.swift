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
    @State private var isImportingBackground = false
    @State private var backgroundImportProgress: Double?
    @State private var backgroundImportCompletedCount = 0
    @State private var backgroundImportTotalCount = 0
    @State private var backgroundImportTask: Task<Void, Never>?
    /// 当前浏览的文件夹（nil = 全部素材），按钮直接切换，不依赖 NavigationLink
    @State private var folderID: String?
    /// 拼接素材选完后交给独立拼接编辑器；普通人物素材选择不需要这个回调。
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

    private enum PickerMode: String, CaseIterable, Identifiable {
        case person
        case background

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .person: "人物素材"
            case .background: "拼接素材"
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

    /// Set 只负责去重；实际排版使用素材库顺序，保证同一批素材每次分区稳定。
    private var orderedSelectedBackgroundIDs: [String] {
        let ordered = appState.backgroundMedia
            .filter { selectedBackgroundIDs.contains($0.id) }
            .map(\.id)
        let known = Set(ordered)
        return ordered + selectedBackgroundIDs.filter { !known.contains($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !collageOnly {
                        folderBar
                        if let folder = currentFolder, !appState.childFolders(of: folder.id).isEmpty {
                            childFolderBar(folder)
                        }
                        clipsGrid
                    } else {
                        backgroundGrid
                    }
                }
                .padding()
            }
            .lfNavigationTitle(collageOnly ? "拼接素材" : (currentFolder?.name ?? "选择人物素材"))
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if pickerMode == .person {
                            for clipID in selectedIDs {
                                appState.addElementFromClipID(clipID)
                            }
                        } else if let onCollageSelection {
                            onCollageSelection(orderedSelectedBackgroundIDs)
                        } else {
                            for mediaID in orderedSelectedBackgroundIDs {
                                appState.addBackgroundElement(mediaID: mediaID)
                            }
                        }
                        dismiss()
                    } label: {
                        let count = pickerMode == .person ? selectedIDs.count : selectedBackgroundIDs.count
                        Text(count == 0 ? "添加" : "添加(\(count))")
                            .fontWeight(.semibold)
                    }
                    .disabled(
                        pickerMode == .person
                            ? selectedIDs.isEmpty
                            : selectedBackgroundIDs.isEmpty || isImportingBackground
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear {
            backgroundImportTask?.cancel()
        }
        .onChange(of: pickerMode) { _, _ in
            selectedIDs.removeAll()
            selectedBackgroundIDs.removeAll()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems.removeAll()
            backgroundImportTask?.cancel()
            backgroundImportTask = Task { @MainActor in
                isImportingBackground = true
                backgroundImportProgress = 0
                backgroundImportCompletedCount = 0
                backgroundImportTotalCount = items.count
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
                await appState.reloadBackgroundMediaAndWait()
                isImportingBackground = false
                backgroundImportTask = nil
            }
        }
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
            .background(isSelected ? LF.selectionFill : LF.surface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(
                        isSelected ? LF.brandTint : LF.textSecondary.opacity(0.16),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .shadow(color: isSelected ? LF.brandTint.opacity(0.16) : .clear, radius: 4, y: 2)
            .foregroundStyle(LF.textPrimary)
        }
        .buttonStyle(.plain)
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
                    message: "去「素材库」页面提取人物素材，\n或在素材上长按移动到文件夹"
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
                            if clip.audioURL != nil {
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

            PhotosPicker(
                selection: $photoItems,
                // 自动排版最多使用四个分区；之后仍可继续分批添加。
                maxSelectionCount: 4,
                matching: .any(of: [.images, .livePhotos, .videos]),
                preferredItemEncoding: .current
            ) {
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
                    Image(systemName: "chevron.right")
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
            .buttonStyle(.plain)

            if isImportingBackground {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在准备拼接素材")
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
                        .buttonStyle(.plain)
                    }
                }
            }

            let media = appState.backgroundMedia.filter { item in
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
    @Binding var isPlaying: Bool
    @State private var framePosition = 0
    /// 点击播放后一次性加载的小尺寸帧；播放期间只切换内存中的 CGImage，避免每帧重复解码。
    @State private var decodedFrames: [CGImage] = []

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
        guard decodedFrames.indices.contains(framePosition) else { return nil }
        return decodedFrames[framePosition]
    }

    var body: some View {
        ZStack {
            CheckerboardView()
            if let decodedFrame {
                ClipPreviewImage(image: decodedFrame, clip: clip)
            } else {
                ClipThumbnailView(clip: clip, index: previewFrame, maxPixelSize: maxPixelSize)
            }
        }
        .task(id: isPlaying) {
            await playOnceIfNeeded()
        }
        .onAppear {
        }
        .onDisappear {
            // 离开滚动区域时取消播放任务，避免不可见素材继续解码和刷新。
            isPlaying = false
            decodedFrames.removeAll(keepingCapacity: false)
        }
        .onChange(of: clip.id) { _, _ in
            framePosition = 0
            isPlaying = false
            decodedFrames.removeAll(keepingCapacity: false)
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing {
                framePosition = 0
            }
        }
    }

    private func playOnceIfNeeded() async {
        guard isPlaying, isDynamic else { return }
        framePosition = 0

        if decodedFrames.isEmpty {
            let clipValue = clip
            let indices = playbackFrames
            let pixelSize = maxPixelSize
            let loaded = await Task.detached(priority: .userInitiated) {
                indices.compactMap { index in
                    FrameCache.shared.cachedThumbnail(
                        for: clipValue,
                        index: index,
                        maxPixelSize: pixelSize
                    )
                }
            }.value
            guard !Task.isCancelled, isPlaying else { return }
            decodedFrames = loaded
        }

        guard decodedFrames.count > 1 else {
            isPlaying = false
            framePosition = 0
            return
        }

        let frameInterval = max(1.0 / max(clip.fps, 1), 0.04)
        for nextPosition in 1..<decodedFrames.count {
            do {
                try await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, isPlaying else { return }
            framePosition = nextPosition
        }

        guard !Task.isCancelled else { return }
        isPlaying = false
        framePosition = 0
    }
}

/// 素材卡片角落的轻量徽标。播放与音频入口共用尺寸和底色，保证左右对齐。
struct ClipPreviewBadgeIcon: View {
    let systemName: String
    var foregroundStyle: Color = .white

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foregroundStyle.opacity(0.9))
            .frame(width: 26, height: 26)
            .background(.black.opacity(0.34), in: Circle())
    }
}

/// 与音频徽标处于同一素材卡片覆盖层，确保不会被预览内容的裁切层隐藏。
struct ClipPreviewPlayButton: View {
    let clip: SegmentedClip
    @Binding var isPlaying: Bool

    var body: some View {
        if clip.frameCount > 1 {
            // 预览卡片外层可能还有“打开详情/选择素材”的 tap gesture。
            // 使用高优先级手势让左下角播放入口始终优先响应，不再被外层点击抢走。
            ClipPreviewBadgeIcon(
                systemName: isPlaying ? "pause.fill" : "play.fill"
            )
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
            .accessibilityLabel(isPlaying ? "暂停动态素材" : "播放动态素材")
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
        .task(id: "\(clip.id)-\(index)-\(Int(maxPixelSize))") {
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

/// 在素材库和编辑页缩略图中复现已保存的边缘效果。
/// 导出仍使用 CompositionRenderer 的完整轮廓算法；这里使用透明帧的柔化轮廓，
/// 让用户在浏览素材时能一眼看出素材是否已经设置过描边/漫画/柔光/投影。
struct ClipPreviewImage: View {
    let image: CGImage
    let clip: SegmentedClip

    private var outlineColor: Color {
        Color(hex: clip.edgeColorHex)
    }

    private var haloRadius: CGFloat {
        max(3, min(clip.edgeThickness.radius / 6, 16))
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

            baseImage
        }
    }

    private var baseImage: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .rotationEffect(.degrees(Double(clip.normalizedRotationQuarterTurns * 90)))
    }

    private func halo(color: Color, radius: CGFloat, opacity: Double) -> some View {
        baseImage
            .colorMultiply(color)
            .blur(radius: radius)
            .opacity(opacity)
    }
}
