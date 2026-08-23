import Combine
import LivingFrameCore
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 编辑页素材选择器：从素材库文件夹中选择素材（可多选）加入画布
struct AssetPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
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

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    private enum PickerMode: String, CaseIterable, Identifiable {
        case person
        case background

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .person: "人物素材"
            case .background: "背景图片"
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
            case .all: "全部背景"
            case .still: "静态"
            case .animated: "动态"
            }
        }
    }

    private var currentFolder: LibraryFolder? {
        appState.folders.first { $0.id == folderID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    modePicker
                    if pickerMode == .person {
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
            .navigationTitle(currentFolder?.name ?? "选择素材")
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
                        } else {
                            for backgroundID in selectedBackgroundIDs {
                                appState.addBackgroundElement(mediaID: backgroundID)
                            }
                        }
                        dismiss()
                    } label: {
                        let count = pickerMode == .person ? selectedIDs.count : selectedBackgroundIDs.count
                        Text(count == 0 ? "添加" : "添加(\(count))")
                            .fontWeight(.semibold)
                    }
                    .disabled(pickerMode == .person ? selectedIDs.isEmpty : selectedBackgroundIDs.isEmpty)
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
                    let imported = await BackgroundPhotoImporter.load(from: item) { progress in
                        Task { @MainActor in
                            guard backgroundImportTotalCount == items.count else { return }
                            let completed = Double(index) / Double(max(items.count, 1))
                            backgroundImportProgress = completed + progress / Double(max(items.count, 1))
                        }
                    }
                    if let imported,
                       let id = appState.importBackgroundMedia(
                        data: imported.data,
                        preferredFileExtension: imported.fileExtension,
                        isVideo: imported.isVideo
                       ) {
                        selectedBackgroundIDs.insert(id)
                    }
                    backgroundImportCompletedCount = index + 1
                    backgroundImportProgress = Double(index + 1) / Double(max(items.count, 1))
                }
                isImportingBackground = false
                backgroundImportTask = nil
            }
        }
    }

    private var modePicker: some View {
        Picker("素材类型", selection: $pickerMode) {
            ForEach(PickerMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
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
        Button {
            folderID = id
            selectedIDs.removeAll()
        } label: {
            HStack(spacing: 6) {
                if id != nil {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(LF.gold)
                }
                Text(title)
                    .lineLimit(1)
                if let id,
                   let folder = appState.folders.first(where: { $0.id == id }) {
                    Text("\(folder.clipIDs.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .contentShape(Capsule())
            .background(folderID == id ? LF.gold : LF.surface2, in: Capsule())
            .foregroundStyle(folderID == id ? .black : LF.textPrimary)
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
                    message: "去「素材库」页面抠出人物素材，\n或在素材上长按移动到文件夹"
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
                                .foregroundStyle(selectedIDs.contains(clip.id) ? LF.gold : LF.textSecondary.opacity(0.5))
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
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: 20,
                matching: .any(of: [.images, .livePhotos]),
                preferredItemEncoding: .current
            ) {
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title2)
                        .foregroundStyle(LF.accent)
                        .frame(width: 42, height: 42)
                        .background(LF.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("从相册选择")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LF.textPrimary)
                        Text("可多选图片或动态照片")
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
                        .stroke(LF.accent.opacity(0.35), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

            if isImportingBackground {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在下载原始动态照片")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(backgroundImportCompletedCount)/\(backgroundImportTotalCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(LF.textSecondary)
                    }
                    if let backgroundImportProgress {
                        ProgressView(value: backgroundImportProgress)
                            .tint(LF.accent)
                    } else {
                        ProgressView()
                            .tint(LF.accent)
                    }
                }
                .padding(12)
                .background(LF.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
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
                                    backgroundFilter == filter ? LF.accent : LF.surface2,
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
                    title: "暂无背景图片",
                    message: "点击上方按钮从相册添加图片"
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
                            } else {
                                selectedBackgroundIDs.insert(item.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// PhotosPicker 的 `Data` 对 Live Photo 通常只返回静态主照片。
/// 用资源库中的 pairedVideo 取回原始 MOV，才能让背景在时间轴和导出中正常播放。
private enum BackgroundPhotoImporter {
    struct ImportedMedia {
        let data: Data
        let fileExtension: String?
        let isVideo: Bool
    }

    static func load(
        from item: PhotosPickerItem,
        progress: @escaping (Double) -> Void
    ) async -> ImportedMedia? {
        // 与「提取素材」使用相同的优先级：先通过 PHAsset 请求原始视频，
        // 再以 PHLivePhoto 的 pairedVideo 资源兜底。两条路径都允许 iCloud 下载。
        if let imported = await livePhotoVideo(from: item, progress: progress) {
            return imported
        }

        progress(0.15)
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first
        progress(1)
        return ImportedMedia(data: data, fileExtension: type?.preferredFilenameExtension, isVideo: false)
    }

    private static func livePhotoVideo(
        from item: PhotosPickerItem,
        progress: @escaping (Double) -> Void
    ) async -> ImportedMedia? {
        if let identifier = item.itemIdentifier,
           let status = await requestPhotoLibraryAccess(),
           (status == .authorized || status == .limited),
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
           asset.mediaSubtypes.contains(.photoLive),
           let imported = await videoFromAsset(asset, progress: progress) {
            return imported
        }

        // iCloud 或受限访问时 itemIdentifier 可能为空；PHLivePhoto 仍能给到 pairedVideo。
        guard let livePhoto = try? await item.loadTransferable(type: PHLivePhoto.self),
              let resource = PHAssetResource.assetResources(for: livePhoto)
                .first(where: { $0.type == .pairedVideo }),
              let data = await resourceData(resource, progress: progress) else {
            return nil
        }
        return ImportedMedia(
            data: data,
            fileExtension: URL(fileURLWithPath: resource.originalFilename).pathExtension,
            isVideo: true
        )
    }

    private static func videoFromAsset(
        _ asset: PHAsset,
        progress: @escaping (Double) -> Void
    ) async -> ImportedMedia? {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in progress(value) }
        let url: URL? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        progress(1)
        return ImportedMedia(data: data, fileExtension: url.pathExtension, isVideo: true)
    }

    private static func resourceData(
        _ resource: PHAssetResource,
        progress: @escaping (Double) -> Void
    ) async -> Data? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-background-\(UUID().uuidString)")
            .appendingPathExtension(URL(fileURLWithPath: resource.originalFilename).pathExtension.isEmpty ? "mov" : URL(fileURLWithPath: resource.originalFilename).pathExtension)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = progress
        let error: Error? = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) {
                continuation.resume(returning: $0)
            }
        }
        defer { try? FileManager.default.removeItem(at: destination) }
        guard error == nil, let data = try? Data(contentsOf: destination) else { return nil }
        progress(1)
        return data
    }

    private static func requestPhotoLibraryAccess() async -> PHAuthorizationStatus? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        default:
            return status
        }
    }
}

private struct BackgroundAssetCell: View {
    let item: BackgroundMediaItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = BackgroundStore.shared.loadFrame(named: item.id, at: 0) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.black.opacity(0.2)
                    }
                }
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if item.isAnimated {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.42), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(4)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? LF.accent : .white.opacity(0.88))
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            HStack(spacing: 4) {
                Text(item.isAnimated ? "动态图片" : "静态图片")
                if item.isAnimated {
                    Text("\(String(format: "%.1fs", item.duration))")
                        .foregroundStyle(LF.textSecondary)
                }
            }
            .font(.caption2)
            .foregroundStyle(LF.textPrimary)
            .lineLimit(1)
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

    private var activeFrames: [Int] {
        clip.activeFrameIndices
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
        guard decodedFrames.indices.contains(framePosition) else { return nil }
        return decodedFrames[framePosition]
    }

    var body: some View {
        ZStack {
            CheckerboardView()
            if let decodedFrame {
                Image(decorative: decodedFrame, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                ClipThumbnailView(clip: clip, index: previewFrame, maxPixelSize: maxPixelSize)
            }
        }
        .task(id: isPlaying) {
            await playOnceIfNeeded()
        }
        .onAppear {
            LogStore.log(
                "clipPreview.appear id=\(clip.id) name=\(clip.name) "
                    + "frameCount=\(clip.frameCount) activeFrames=\(activeFrames.count) "
                    + "isDynamic=\(isDynamic) showsPlayButton=\(isDynamic) "
                    + "fps=\(clip.fps) maxPixelSize=\(Int(maxPixelSize))"
            )
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
            Button {
                let action = isPlaying ? "pause" : "play"
                LogStore.log(
                    "clipPreview.buttonTapped id=\(clip.id) name=\(clip.name) "
                        + "action=\(action) frameCount=\(clip.frameCount) "
                        + "activeFrames=\(clip.activeFrameIndices.count)"
                )
                isPlaying.toggle()
            } label: {
                ClipPreviewBadgeIcon(
                    systemName: isPlaying ? "pause.fill" : "play.fill"
                )
            }
            .buttonStyle(.plain)
            .padding(4)
            .contentShape(Rectangle())
            .accessibilityLabel(isPlaying ? "暂停动态素材" : "播放动态素材")
        }
    }
}

struct AssetCell: View {
    let clip: SegmentedClip
    let onSelect: () -> Void
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 4) {
            AnimatedClipPreview(clip: clip, maxPixelSize: 320, isPlaying: $isPlaying)
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    ClipPreviewPlayButton(clip: clip, isPlaying: $isPlaying)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }

            Text(clip.name)
                .font(.caption2)
                .foregroundStyle(LF.textPrimary)
                .lineLimit(1)
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
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
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
