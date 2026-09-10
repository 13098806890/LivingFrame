import AVFoundation
import AVKit
import LivingFrameCore
import PhotosUI
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var loadError: String?
    /// iCloud 素材下载进度（nil 表示进度未知）
    @State private var isDownloading = false
    @State private var downloadProgress: Double?
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    /// 当前拖拽悬停的目标文件夹（用于高亮）
    @State private var dragOverFolderID: String?
    /// 单击素材打开的详情页（nil = 不显示）
    @State private var menuClip: SegmentedClip?
    /// 普通路径默认提取动态素材；静态首帧作为高级选项。
    @State private var defaultExtractKind: ExtractKind = .live
    /// 超过 1 分钟的视频，在动态提取前选择源视频范围。
    @State private var pendingVideoRange: PendingVideoRange?
    /// 当前批量提取的队列位置；提取仍串行执行以控制内存占用。
    @State private var extractionQueuePosition: Int?
    @State private var extractionQueueTotal = 0
    @State private var importTask: Task<Void, Never>?

    private struct PendingVideoRange: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let duration: TimeInterval
        let maxDuration: TimeInterval
        var resume: (ClosedRange<TimeInterval>?) -> Void
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isDownloading {
                    downloadCard
                }
                if isExtractionActive {
                    segmentationCard
                }
                pickerSection
                foldersSection
                clipsSection
            }
            .padding(.horizontal)
            .navigationTitle("素材库")
            .magicBackground()
            .alert("新建文件夹", isPresented: $showNewFolderAlert) {
                TextField("文件夹名称", text: $newFolderName)
                Button("创建") {
                    appState.createFolder(named: newFolderName)
                    newFolderName = ""
                }
                Button("取消", role: .cancel) {
                    newFolderName = ""
                }
            } message: {
                Text("整理人物素材")
            }
            .alert(
                NSLocalizedString(
                    loadError != nil ? "导入失败" : "人物素材生成失败",
                    comment: "Import alert title"
                ),
                isPresented: Binding(
                    get: { loadErrorMessage != nil },
                    set: { if !$0 { loadError = nil; appState.segmentationError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loadErrorMessage ?? "")
            }
            .sheet(item: $pendingVideoRange, onDismiss: {
                pendingVideoRange?.resume(nil)
                pendingVideoRange = nil
            }) { request in
                VideoRangePickerView(
                    url: request.url,
                    name: request.name,
                    duration: request.duration,
                    maxDuration: request.maxDuration,
                    onCancel: {
                        request.resume(nil)
                        pendingVideoRange = nil
                    },
                    onConfirm: { range in
                        request.resume(range)
                        pendingVideoRange = nil
                    }
                )
            }
            .sheet(item: $menuClip) { clip in
                ClipMenuView(
                    clip: clip,
                    onClose: { menuClip = nil }
                )
                .environmentObject(appState)
            }
            .onDisappear {
                importTask?.cancel()
            }
        }
    }

    // MARK: - 素材入口

    private var pickerSection: some View {
        VStack(spacing: 8) {
            PhotosPicker(
                selection: $pickerItems,
                maxSelectionCount: 5,
                matching: .any(of: [.videos, .livePhotos, .images])
            ) {
                SectionCard(title: nil) {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 34))
                            .foregroundStyle(LF.gold)
                        Text("选择视频 / Live Photo / 照片")
                            .font(.headline)
                        Text("自动提取人物，生成透明人物素材，全程在设备端处理")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)

            Menu {
                Section("提取方式") {
                    Button {
                        defaultExtractKind = .live
                    } label: {
                        Label("动态人物（默认）", systemImage: defaultExtractKind == .live ? "checkmark" : "sparkles")
                    }
                    Button {
                        defaultExtractKind = .static
                    } label: {
                        Label("静态人物（只取首帧）", systemImage: defaultExtractKind == .static ? "checkmark" : "photo")
                    }
                }

                Section("提取帧率") {
                    ForEach(AppState.processingFPSOptions, id: \.self) { option in
                        Button {
                            appState.processingFPS = option
                        } label: {
                            Label(
                                "\(fpsTitle(option)) fps",
                                systemImage: abs(appState.processingFPS - option) < 0.01 ? "checkmark" : "circle"
                            )
                        }
                    }
                }
            } label: {
                Label(
                    extractionSettingsLabel,
                    systemImage: "slider.horizontal.3"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(LF.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("人物素材设置")
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems.removeAll()
            importTask = Task { @MainActor in
                // 1. 并行下载所有选中素材（iCloud 下载可多线程加速）
                var downloadedSources: [(index: Int, source: ImportSource)] = []
                isDownloading = true
                downloadProgress = nil
                await withTaskGroup(of: (Int, ImportSource?).self) { group in
                    for (index, item) in items.enumerated() {
                        group.addTask { (index, await load(item)) }
                    }
                    for await result in group {
                        if let source = result.1 {
                            downloadedSources.append((result.0, source))
                        }
                    }
                }
                // 下载完成即隐藏下载进度条（抠图阶段由「正在抠图」卡片展示）
                isDownloading = false
                let sources = downloadedSources
                    .sorted { $0.index < $1.index }
                    .map(\.source)
                guard !Task.isCancelled, !sources.isEmpty else { return }

                // 2. 视频默认直接按动态素材提取；需要静态首帧时再从高级选项进入。
                startExtraction(
                    sources: sources,
                    kinds: sources.map { isVideoSource($0) ? defaultExtractKind : .static }
                )
            }
        }
    }

    private func fpsTitle(_ fps: Double) -> String {
        if abs(fps.rounded() - fps) < 0.01 { return String(Int(fps.rounded())) }
        return String(format: "%.1f", fps)
    }

    private var extractionSettingsLabel: String {
        let kind = defaultExtractKind == .live
            ? NSLocalizedString("动态人物", comment: "Animated person asset")
            : NSLocalizedString("静态人物", comment: "Still person asset")
        return String(
            format: NSLocalizedString("人物素材 · %@ · %@ fps", comment: "Person asset extraction summary"),
            kind,
            fpsTitle(appState.processingFPS)
        )
    }

    private enum ExtractKind: Hashable {
        case live
        case `static`
    }

    private func isVideoSource(_ source: ImportSource) -> Bool {
        if case .video = source { return true }
        return false
    }

    /// 按选择的方式串行提取，保留原有的方向、首帧和长视频范围逻辑。
    private func startExtraction(sources: [ImportSource], kinds: [ExtractKind]) {
        importTask?.cancel()
        extractionQueueTotal = sources.count
        extractionQueuePosition = nil
        importTask = Task { @MainActor in
            for (index, pair) in zip(sources.indices, zip(sources, kinds)) {
                guard !Task.isCancelled else { break }
                extractionQueuePosition = index + 1
                let source = pair.0
                let kind = pair.1
                switch source {
                case .video(let url, let name, let stillOrientation, let stillURL):
                    switch kind {
                    case .live:
                        let duration = await videoDuration(of: url)
                        if duration > 60 {
                            let range: ClosedRange<TimeInterval>? = await withCheckedContinuation { continuation in
                                pendingVideoRange = PendingVideoRange(
                                    url: url,
                                    name: name,
                                    duration: duration,
                                    maxDuration: appState.maxExtractionDuration
                                ) { selectedRange in
                                    continuation.resume(returning: selectedRange)
                                }
                            }
                            guard let range else { continue }
                            await appState.startSegmenting(
                                url: url,
                                name: name,
                                sourceStartTime: range.lowerBound,
                                sourceEndTime: range.upperBound,
                                stillOrientation: stillOrientation
                            )
                        } else {
                            await appState.startSegmenting(
                                url: url,
                                name: name,
                                stillOrientation: stillOrientation
                            )
                        }
                    case .static:
                        if let cgImage = await firstFrame(of: url, stillURL: stillURL) {
                            await appState.startPhotoSegmenting(cgImage: cgImage, name: name)
                        }
                    }
                case .photo(let cgImage, let name):
                    await appState.startPhotoSegmenting(cgImage: cgImage, name: name)
                }
            }
            extractionQueuePosition = nil
            extractionQueueTotal = 0
        }
    }

    private func videoDuration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    private var loadErrorMessage: String? {
        loadError ?? appState.segmentationError
    }

    /// 下载完成的待抠图素材（下载与抠图分离：下载并行，抠图串行）
    /// stillURL：Live Photo 的配套静态图（可选，非 Live 为 nil）
    private enum ImportSource {
        case video(url: URL, name: String, stillOrientation: CGImagePropertyOrientation, stillURL: URL?)
        case photo(cgImage: CGImage, name: String)
    }

    private func load(_ item: PhotosPickerItem) async -> ImportSource? {
        let types = item.supportedContentTypes
        LogStore.log("load: itemIdentifier=\(item.itemIdentifier ?? "nil") types=\(types.map(\.identifier))")
        // 1. Live Photo：PHAsset 视频轨优先，PHLivePhoto 传输兜底
        //    （iCloud 未下载的 Live Photo 常不报 live-photo 类型、itemIdentifier 为 nil）
        if let source = await loadLivePhoto(item: item) { return source }
        // 2. 视频
        if types.contains(where: { $0.conforms(to: .movie) }),
           let source = await loadMovie(item: item) { return source }
        // 3. 普通照片：单帧抠图
        if types.contains(where: { $0.conforms(to: .image) }),
           let source = await loadPhoto(item: item) { return source }
        await MainActor.run {
            loadError = NSLocalizedString("无法读取所选素材", comment: "Load failure detail")
        }
        return nil
    }

    private func loadLivePhoto(item: PhotosPickerItem) async -> ImportSource? {
        let progressHandler: @Sendable (Double) -> Void = { value in
            Task { @MainActor in self.downloadProgress = value }
        }
        guard let video = await PhotoLibraryMediaImporter.loadExtractionVideo(
            from: item,
            progress: progressHandler
        ) else { return nil }
        return .video(
            url: video.url,
            name: video.name,
            stillOrientation: video.stillOrientation,
            stillURL: video.stillURL
        )
    }

    private func loadMovie(item: PhotosPickerItem) async -> ImportSource? {
        guard let movie = try? await item.loadTransferable(type: MovieFile.self) else {
            LogStore.log("loadMovie: MovieFile load failed")
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: movie.url.path)[.size] as? Int) ?? 0
        LogStore.log("loadMovie: URL=\(movie.url.path) size=\(size) bytes")
        return .video(url: movie.url, name: movie.url.lastPathComponent, stillOrientation: .up, stillURL: nil)
    }

    private func loadPhoto(item: PhotosPickerItem) async -> ImportSource? {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            LogStore.log("loadPhoto: Data load failed")
            return nil
        }
        guard let image = UIImage(data: data),
              let fixed = image.fixedOrientation() else {
            LogStore.log("loadPhoto: UIImage decode failed data=\(data.count) bytes")
            return nil
        }
        LogStore.log("loadPhoto: data=\(data.count) bytes size=\(image.size.width)x\(image.size.height) orientation=\(image.imageOrientation.rawValue)")
        return .photo(
            cgImage: fixed,
            name: NSLocalizedString("照片", comment: "Photo clip name")
        )
    }

    private func copyToTemporaryFile(_ url: URL) async throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-import-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// 静态贴纸源图：Live Photo 用配套静态图，普通视频取首帧
    private func firstFrame(of videoURL: URL, stillURL: URL?) async -> CGImage? {
        if let stillURL {
            // 用 fixedOrientation() 应用 EXIF 朝向，避免竖拍照片被旋转
            guard let fixed = UIImage(contentsOfFile: stillURL.path)?.fixedOrientation() else {
                LogStore.log("firstFrame: still image decode failed")
                return nil
            }
            return fixed
        }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let (image, _) = try await generator.image(at: .zero)
            LogStore.log("firstFrame: video first frame \(image.width)x\(image.height)")
            return image
        } catch {
            LogStore.log("firstFrame: video first frame failed error=\(error)")
            return nil
        }
    }

    // MARK: - 文件夹

    /// 文件夹栏：最左侧「新建」固定不动，右侧已有文件夹可横向滑动
    private var foldersSection: some View {
        SectionCard(title: nil) {
            HStack(spacing: 10) {
                // 新建（图标按钮，固定位置，不随滚动）
                Button {
                    showNewFolderAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.title3)
                        .frame(width: 46, height: 46)
                        .background(LF.surface2.opacity(0.5), in: Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(LF.surface2, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        .foregroundStyle(LF.textPrimary)
                }
                .buttonStyle(.plain)
                .fixedSize()

                // 已有文件夹（可横向滑动）
                if appState.rootFolders().isEmpty {
                    Text(NSLocalizedString("还没有文件夹", comment: "No folders"))
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(appState.rootFolders()) { folder in
                                NavigationLink {
                                    FolderDetailView(folder: folder)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "folder.fill")
                                            .font(.title2)
                                            .foregroundStyle(LF.folderIcon)
                                        Text(folder.name)
                                            .lineLimit(1)
                                        Text("\(folder.clipIDs.count)")
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(dragOverFolderID == folder.id ? LF.folderIcon : LF.textSecondary)
                                        if appState.hasChildFolders(folder.id) {
                                            Image(systemName: "chevron.right")
                                                .font(.caption2)
                                                .foregroundStyle(dragOverFolderID == folder.id ? LF.folderIcon : LF.textSecondary)
                                        }
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .frame(minHeight: 56)
                                    .contentShape(Capsule())
                                    .background(
                                        dragOverFolderID == folder.id ? LF.selectionFill : LF.surface2,
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(
                                                dragOverFolderID == folder.id ? LF.brandTint : .clear,
                                                lineWidth: 2
                                            )
                                    }
                                    .foregroundStyle(LF.textPrimary)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        appState.deleteFolder(folder)
                                    } label: {
                                        Label(NSLocalizedString("删除文件夹", comment: "Delete folder"), systemImage: "trash")
                                    }
                                }
                                // 拖拽素材到此文件夹
                                .dropDestination(for: String.self) { clipIDs, _ in
                                    for clipID in clipIDs {
                                        appState.moveClip(clipID, toFolder: folder.id)
                                    }
                                    dragOverFolderID = nil
                                    return true
                                } isTargeted: { targeted in
                                    dragOverFolderID = targeted ? folder.id : nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 下载 / 保存进度

    private var downloadCard: some View {
        SectionCard(title: "正在下载") {
            HStack {
                if let downloadProgress {
                    ProgressView(value: downloadProgress)
                        .tint(LF.gold)
                    Text(String(format: "%d%%", Int(downloadProgress * 100)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                } else {
                    ProgressView()
                        .tint(LF.gold)
                    Text("从 iCloud 下载中…")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
            }
        }
    }

    // MARK: - 抠图进度

    private var isExtractionActive: Bool {
        appState.isSegmenting || extractionQueuePosition != nil
    }

    private var segmentationCard: some View {
        SectionCard(title: "正在生成素材") {
            HStack {
                if appState.isSegmenting {
                    ProgressView(value: appState.segmentationProgress)
                        .tint(LF.gold)
                    Text(String(format: "%d%%", Int(appState.segmentationProgress * 100)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                } else {
                    ProgressView()
                        .tint(LF.gold)
                    Text("准备中…")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
            }
            if let extractionQueuePosition {
                Text("第 \(extractionQueuePosition)/\(extractionQueueTotal) 个素材")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.header)
            }
            Text(appState.segmentingName.isEmpty ? "正在准备人物素材" : appState.segmentingName)
                .font(.caption)
                .foregroundStyle(LF.textSecondary)
                .lineLimit(1)
            Text("本次最多处理 \(Int(appState.maxExtractionDuration)) 秒，超出部分从开头截取")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            Button("取消生成", role: .cancel) {
                importTask?.cancel()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 素材网格

    private var clipsSection: some View {
        SectionCard(title: NSLocalizedString("全部素材", comment: "All clips")) {
            if appState.clips.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "还没有素材",
                    message: "选择视频、Live Photo 或照片，\n人物会被自动提取为透明素材"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(appState.clips) { clip in
                            // 单击 = 打开素材详情；拖拽从右上角把手开始。
                            ZStack(alignment: .topTrailing) {
                                ClipCell(clip: clip) {
                                    menuClip = clip
                                }

                                // 拖入文件夹改为从明确的拖拽把手开始，避免播放按钮
                                // 在素材缩略图尚未完成解码时被系统拖拽手势抢走。
                                Image(systemName: "line.3.horizontal")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(LF.textSecondary)
                                    .frame(width: 30, height: 30)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .contentShape(Circle())
                                    .draggable(clip.id) {
                                        ClipDragPreview(clip: clip)
                                    }
                                    .accessibilityLabel("拖动到文件夹")
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct VideoRangePickerView: View {
    let url: URL
    let name: String
    let duration: TimeInterval
    let maxDuration: TimeInterval
    let onCancel: () -> Void
    let onConfirm: (ClosedRange<TimeInterval>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startTime: TimeInterval
    @State private var endTime: TimeInterval
    @State private var selectedDetent: PresentationDetent = .large
    @State private var videoAspectRatio: CGFloat = 16.0 / 9.0
    @StateObject private var previewController: VideoRangePreviewController

    init(
        url: URL,
        name: String,
        duration: TimeInterval,
        maxDuration: TimeInterval,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ClosedRange<TimeInterval>) -> Void
    ) {
        let safeDuration = max(duration, 0.1)
        let safeMaxDuration = max(maxDuration, 0.1)
        self.url = url
        self.name = name
        self.duration = safeDuration
        self.maxDuration = safeMaxDuration
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _startTime = State(initialValue: 0)
        _endTime = State(initialValue: min(safeDuration, safeMaxDuration))
        _previewController = StateObject(wrappedValue: VideoRangePreviewController(url: url))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择要提取的视频片段")
                            .font(.headline)
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                            .lineLimit(1)
                    }

                    ZStack(alignment: .topLeading) {
                        VideoPlayer(player: previewController.player)
                            .aspectRatio(videoAspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .background(.black)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Label("预览选中片段", systemImage: "play.rectangle.fill")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.58), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }

                    VideoRangeTimeline(
                        url: url,
                        duration: duration,
                        startTime: $startTime,
                        endTime: $endTime,
                        maxDuration: maxDuration
                    )

                    HStack(spacing: 10) {
                        Label(
                            "已选 \(formatTimestamp(endTime - startTime))",
                            systemImage: "scissors"
                        )
                        Spacer(minLength: 8)
                        Text("\(formatTimestamp(startTime)) – \(formatTimestamp(endTime))")
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LF.textSecondary)

                    Button {
                        if previewController.isPlaying {
                            previewController.stop()
                        } else {
                            previewController.preview(start: startTime, end: endTime)
                        }
                    } label: {
                        Label(
                            previewController.isPlaying ? "停止预览" : "预览选中片段",
                            systemImage: previewController.isPlaying ? "stop.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LF.header)
                }
                .padding(20)
            }
            .lfNavigationTitle("视频范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提取人物") {
                        onConfirm(startTime...endTime)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .magicBackground()
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(LF.background.opacity(0.94), for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .onChange(of: startTime) { _, _ in
            if previewController.isPlaying { previewController.stop() }
        }
        .onChange(of: endTime) { _, _ in
            if previewController.isPlaying { previewController.stop() }
        }
        .onDisappear {
            previewController.stop()
        }
        .task(id: url) {
            await loadVideoAspectRatio()
        }
    }

    private func formatTimestamp(_ value: TimeInterval) -> String {
        let safeValue = max(value, 0)
        return String(format: "%d:%04.1f", Int(safeValue) / 60, safeValue.truncatingRemainder(dividingBy: 60))
    }

    private func loadVideoAspectRatio() async {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let naturalSize = try? await track.load(.naturalSize),
              let preferredTransform = try? await track.load(.preferredTransform) else {
            return
        }
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = abs(transformedSize.width)
        let height = abs(transformedSize.height)
        guard width > 0, height > 0, !Task.isCancelled else { return }
        videoAspectRatio = width / height
    }
}

@MainActor
private final class VideoRangePreviewController: ObservableObject {
    let player: AVPlayer
    @Published private(set) var isPlaying = false
    private var boundaryObserver: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
    }

    func preview(start: TimeInterval, end: TimeInterval) {
        removeBoundaryObserver()
        let startTime = CMTime(seconds: max(start, 0), preferredTimescale: 600)
        let endTime = CMTime(seconds: max(end, start + 0.1), preferredTimescale: 600)
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.pause()
                self.player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                self.isPlaying = false
            }
        }
        isPlaying = true
        player.play()
    }

    func stop() {
        player.pause()
        removeBoundaryObserver()
        isPlaying = false
    }

    private func removeBoundaryObserver() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
    }

    deinit {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
        }
    }
}

private struct VideoRangeTimeline: View {
    let url: URL
    let duration: TimeInterval
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval
    let maxDuration: TimeInterval

    @State private var thumbnails: [CGImage] = []
    @State private var activeHandle: Handle?
    @State private var dragStartTime: TimeInterval = 0
    @State private var dragEndTime: TimeInterval = 0
    @State private var dragTimelineOffset: CGFloat = 0
    @State private var timelineOffset: CGFloat = 0

    private enum Handle {
        case start
        case end
        case range
    }

    private var maximumSelectionDuration: TimeInterval {
        min(max(maxDuration, 0.1), duration)
    }

    private var minimumSelectionDuration: TimeInterval { 0.1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("拖动视频选择片段")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.header)
                Spacer()
                Text("起点 \(formatTimestamp(startTime)) · 选中 \(formatTimestamp(endTime - startTime))")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let maximumSelectionWidth = min(width * 0.5, max(width - 36, 1))
                let selectedDuration = min(
                    max(endTime - startTime, minimumSelectionDuration),
                    maximumSelectionDuration
                )
                let selectionWidth = min(
                    max(28, maximumSelectionWidth * CGFloat(selectedDuration / maximumSelectionDuration)),
                    max(width - 24, 28)
                )
                let timelinePadding: CGFloat = 12
                let timelineScale = maximumSelectionWidth / CGFloat(maximumSelectionDuration)
                let contentWidth = max(
                    width,
                    CGFloat(duration) * timelineScale
                )
                // bar 拖动时，bar 相对固定的缩略图轨道移动；
                // 拖动 bar 以外的区域时，时间窗口固定，缩略图在窗口下方移动。
                let selectionX = timelinePadding + CGFloat(startTime) * timelineScale + timelineOffset
                let handleWidth: CGFloat = 18

                ZStack(alignment: .leading) {
                    // 内容层单独裁切，避免贴近左边界的起始 bar 被圆角裁掉。
                    thumbnailStrip(contentWidth: contentWidth, height: 82)
                        .offset(x: timelineOffset)
                        .frame(width: width, height: 86, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // 遮罩和选区框固定在 viewport 层，不能放进会随着完整视频宽度
                    // 参与布局的 content 层。
                    TimelineInactiveRangeMask(
                        totalWidth: width,
                        leftWidth: selectionX,
                        rightWidth: width - selectionX - selectionWidth,
                        height: 82
                    )
                    .frame(width: width, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .zIndex(10)

                    // 选区边框放在遮罩之上。
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(LF.selectionStroke, lineWidth: 3)
                        .frame(width: selectionWidth, height: 86)
                        .offset(x: selectionX)
                        .shadow(color: LF.selectionText.opacity(0.32), radius: 3, y: 1)
                        .zIndex(20)

                    timelineHandle
                        .frame(width: handleWidth)
                        .offset(x: selectionX - handleWidth / 2)
                        .zIndex(30)
                    timelineHandle
                        .frame(width: handleWidth)
                        .offset(x: selectionX + selectionWidth - handleWidth / 2)
                        .zIndex(30)
                }
                .frame(width: width, height: 96)
                .contentShape(Rectangle())
                // 与外层纵向 ScrollView 同时接收事件；只有水平位移超过垂直位移
                // 才建立时间轴拖动会话，避免轻微上下滑动被时间轴抢走。
                .simultaneousGesture(
                    dragGesture(
                        selectionX: selectionX,
                        selectionWidth: selectionWidth,
                        timelineScale: timelineScale,
                        contentWidth: contentWidth,
                        viewportWidth: width
                    )
                )
            }
            .frame(height: 96)

            HStack {
                Text(formatTimestamp(0))
                Spacer()
                Label("拖动选区或边界", systemImage: "hand.draw")
                    .foregroundStyle(LF.selectionStroke)
                Spacer()
                Text(formatTimestamp(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(LF.textSecondary)
        }
        .task(id: url) {
            await loadThumbnails()
        }
    }

    private func thumbnailStrip(contentWidth: CGFloat, height: CGFloat) -> some View {
        let count = max(thumbnails.count, 24)
        let itemWidth = max((contentWidth - CGFloat(count - 1)) / CGFloat(count), 1)

        return HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { index in
                if index < thumbnails.count {
                    Image(decorative: thumbnails[index], scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: itemWidth, height: height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [LF.selectionFill, LF.surface2],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: itemWidth, height: height)
                }
            }
        }
        .frame(width: contentWidth, height: height, alignment: .leading)
        .background(LF.surface2)
    }

    private var timelineHandle: some View {
        Capsule()
            .fill(LF.selectionStroke)
            .frame(width: 18, height: 96)
            .overlay {
                HStack(spacing: 3) {
                    Capsule()
                        .fill(LF.selectionText.opacity(0.72))
                        .frame(width: 2, height: 14)
                    Capsule()
                        .fill(LF.selectionText.opacity(0.72))
                        .frame(width: 2, height: 14)
                }
            }
            .overlay {
                Capsule()
                    .stroke(LF.selectionFill, lineWidth: 1)
            }
            .shadow(color: LF.selectionText.opacity(0.28), radius: 3, y: 1)
    }

    private func dragGesture(
        selectionX: CGFloat,
        selectionWidth: CGFloat,
        timelineScale: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if activeHandle == nil {
                    guard abs(value.translation.width) > abs(value.translation.height) else {
                        return
                    }
                    dragStartTime = startTime
                    dragEndTime = endTime
                    dragTimelineOffset = timelineOffset
                    activeHandle = handle(
                        at: value.startLocation.x,
                        selectionX: selectionX,
                        selectionWidth: selectionWidth
                    )
                }

                let delta = TimeInterval(value.translation.width / max(timelineScale, 1))
                switch activeHandle {
                case .some(.start):
                    let proposedStart = min(max(dragStartTime + delta, 0), dragEndTime - minimumSelectionDuration)
                    let maximumLengthStart = max(dragEndTime - maximumSelectionDuration, 0)
                    if proposedStart < maximumLengthStart {
                        // 从左侧继续拖动时已达到最大时长：两个 bar 一起向左移动。
                        startTime = proposedStart
                        endTime = min(proposedStart + maximumSelectionDuration, duration)
                    } else {
                        startTime = proposedStart
                    }
                case .some(.end):
                    let minimum = min(duration, dragStartTime + minimumSelectionDuration)
                    let proposedEnd = min(max(dragEndTime + delta, minimum), duration)
                    let maximumLengthEnd = dragStartTime + maximumSelectionDuration
                    if proposedEnd > maximumLengthEnd {
                        // 达到最大时长后继续向右拖：整段选区一起向右移动，长度保持不变。
                        let shiftedStart = min(
                            proposedEnd - maximumSelectionDuration,
                            max(duration - maximumSelectionDuration, 0)
                        )
                        startTime = max(shiftedStart, 0)
                        endTime = min(startTime + maximumSelectionDuration, duration)
                    } else {
                        endTime = proposedEnd
                    }
                case .some(.range), nil:
                    let length = dragEndTime - dragStartTime
                    let maximumStart = max(duration - length, 0)
                    // 时间轴平移方向与手势一致：手指向左，底部缩略图向左，
                    // 选取窗口对应的时间向后移动。
                    let timelineDelta = -delta
                    let newStart = min(max(dragStartTime + timelineDelta, 0), maximumStart)
                    startTime = newStart
                    endTime = newStart + length
                    // 通过反向移动缩略图，保持选区两侧 bar 的屏幕位置不变。
                    let offset = dragTimelineOffset - CGFloat(newStart - dragStartTime) * timelineScale
                    let minimumOffset = -max(contentWidth - viewportWidth, 0)
                    timelineOffset = min(max(offset, minimumOffset), 0)
                }
            }
            .onEnded { _ in
                activeHandle = nil
            }
    }

    private func handle(at x: CGFloat, selectionX: CGFloat, selectionWidth: CGFloat) -> Handle {
        let left = selectionX
        let right = selectionX + selectionWidth
        // 热区只略大于视觉 bar，把 bar 以外的区域留给时间窗口平移。
        // 当选区很短、两侧热区重叠时，按距离最近的一侧处理，避免总是误判成起点。
        let hitSlop: CGFloat = 10
        let distanceToStart = abs(x - left)
        let distanceToEnd = abs(x - right)
        if distanceToStart <= hitSlop || distanceToEnd <= hitSlop {
            return distanceToStart <= distanceToEnd ? .start : .end
        }
        return .range
    }

    private func loadThumbnails() async {
        let requestedURL = url
        let requestedDuration = duration
        let images = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: requestedURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let count = 24
            return (0..<count).compactMap { index -> CGImage? in
                let progress = Double(index) / Double(max(count - 1, 1))
                let time = CMTime(
                    seconds: requestedDuration * progress,
                    preferredTimescale: 600
                )
                return try? generator.copyCGImage(at: time, actualTime: nil)
            }
        }.value

        guard !Task.isCancelled else { return }
        thumbnails = images
    }

    private func formatTimestamp(_ value: TimeInterval) -> String {
        let safeValue = max(value, 0)
        return String(format: "%d:%04.1f", Int(safeValue) / 60, safeValue.truncatingRemainder(dividingBy: 60))
    }
}

struct ClipCell: View {
    let clip: SegmentedClip
    let onOpen: (() -> Void)?
    @State private var isPlaying = false

    init(clip: SegmentedClip, onOpen: (() -> Void)? = nil) {
        self.clip = clip
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                AnimatedClipPreview(clip: clip, maxPixelSize: 320, isPlaying: $isPlaying)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                if clip.frameCount > 1 {
                    // 这里只负责显示，真正的点击分流由预览区的 SpatialTapGesture 处理，
                    // 避免外层详情点击手势再次抢走播放入口。
                    ClipPreviewBadgeIcon(
                        systemName: isPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(width: 44, height: 44)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if clip.audioURL != nil {
                    ClipPreviewBadgeIcon(
                        systemName: "waveform",
                        foregroundStyle: LF.gold
                    )
                        .padding(4)
                }
            }
            // 播放按钮固定在左下角，边缘样式徽标移到左上角，避免遮挡动态素材播放入口。
            .overlay(alignment: .topLeading) {
                if clip.edgeStyle != .none {
                    Image(systemName: "square.dashed")
                        .font(.caption)
                        .foregroundStyle(LF.gold)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(4)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(LF.surface2, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .highPriorityGesture(
                SpatialTapGesture().onEnded { value in
                    let playArea = CGRect(x: 0, y: 56, width: 72, height: 64)
                    if clip.frameCount > 1, playArea.contains(value.location) {
                        isPlaying.toggle()
                    } else {
                        onOpen?()
                    }
                }
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(clip.width)×\(clip.height) · \(Int(clip.fps.rounded()))fps · \(clip.frameCount)帧")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                onOpen?()
            }
        }
    }
}

/// 素材详情页的预览按源素材比例展示，不复用素材库的固定高度卡片。
private struct ClipDetailPreview: View {
    let clip: SegmentedClip
    @Binding var isPlaying: Bool

    /// 详情页只负责检查原始素材，不在这里模拟编辑器/导出的边缘效果。
    private var unstyledClip: SegmentedClip {
        var value = clip
        value.edgeStyle = .none
        return value
    }

    private var aspectRatio: CGFloat {
        CGFloat(max(clip.orientedWidth, 1)) / CGFloat(max(clip.orientedHeight, 1))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AnimatedClipPreview(clip: unstyledClip, maxPixelSize: 640, isPlaying: $isPlaying)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if clip.frameCount > 1 {
                ClipPreviewPlayButton(clip: clip, isPlaying: $isPlaying)
                    .padding(4)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LF.surface2, lineWidth: 1)
        }
    }
}

/// 素材详情页：单击素材后进入，集中处理原始预览、帧编辑和文件夹管理。
struct ClipMenuView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let clip: SegmentedClip
    let onClose: () -> Void
    @State private var showFrameEditor = false
    @State private var isPlayingPreview = false
    @State private var showDeleteConfirmation = false
    @State private var showReferencedWorkAlert = false
    @State private var referencedWorkNames: [String] = []
    @State private var isDeletingClip = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    /// 读取最新值，避免详情页打开后修改样式仍显示旧状态。
    private var currentClip: SegmentedClip {
        appState.clips.first(where: { $0.id == clip.id }) ?? clip
    }

    /// 素材当前是否已在指定文件夹。
    private func isFiled(_ folderID: String) -> Bool {
        appState.folders.contains { $0.id == folderID && $0.clipIDs.contains(clip.id) }
    }

    private func close() {
        onClose()
        dismiss()
    }

    var body: some View {
        NavigationStack {
            detailScrollView
            .lfNavigationTitle("素材详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { close() }
                }
            }
            .magicBackground()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showFrameEditor) {
            FrameGridView(clipID: clip.id)
                .environmentObject(appState)
        }
        .confirmationDialog("删除素材？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard !isDeletingClip else { return }
                isDeletingClip = true
                appState.deleteClip(clip.id)
                close()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，但不会影响素材库中的其他内容。")
        }
        .alert("素材正在使用中", isPresented: $showReferencedWorkAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请先从以下作品中移除它，再删除素材：\n\(referencedWorkNames.joined(separator: "、"))")
        }
        .alert("重命名素材", isPresented: $showRenameAlert) {
            TextField("素材名称", text: $renameText)
            Button("保存") {
                appState.renameClip(clip.id, to: renameText)
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var detailScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                clipIdentityHeader
                ClipDetailPreview(clip: currentClip, isPlaying: $isPlayingPreview)
                rotateClipButton
                frameEditorButton
                foldersSection
                deleteClipButton
            }
            .padding(20)
        }
    }

    private var clipIdentityHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(currentClip.name)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(currentClip.orientedWidth)×\(currentClip.orientedHeight) · \(Int(currentClip.fps.rounded())) fps · \(currentClip.frameCount) 帧")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }
            Spacer()
            Button {
                renameText = currentClip.name
                showRenameAlert = true
            } label: {
                Image(systemName: "pencil.line")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(LF.surface2, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑素材名称")
        }
    }

    private var rotateClipButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                appState.rotateClip(clip.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rotate.right")
                    .foregroundStyle(LF.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text("旋转 90°")
                        .font(.subheadline.weight(.semibold))
                    Text("当前方向：\(currentClip.normalizedRotationQuarterTurns * 90)°")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)
            }
            .padding(14)
            .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var frameEditorButton: some View {
        Button {
            showFrameEditor = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.3x3")
                    .foregroundStyle(LF.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text("编辑帧")
                        .font(.subheadline.weight(.semibold))
                    Text("取舍帧，让动态素材更轻、更顺")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)
            }
            .padding(14)
            .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文件夹")
                    .font(.headline)
                    .foregroundStyle(LF.header)
                Spacer()
                Text("选择后会移动到该文件夹")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }

            if appState.folders.isEmpty {
                Text("还没有文件夹，可先在素材库创建")
                    .font(.subheadline)
                    .foregroundStyle(LF.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(appState.folders) { folder in
                    folderButton(folder)
                }
            }
        }
    }

    private func folderButton(_ folder: LibraryFolder) -> some View {
        let filed = isFiled(folder.id)
        return Button {
            appState.moveClip(clip.id, toFolder: filed ? nil : folder.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: filed ? "folder.fill" : "folder")
                    .foregroundStyle(LF.folderIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .lineLimit(1)
                    Text("\(folder.clipIDs.count) 个素材")
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer()
                Image(systemName: filed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(filed ? LF.gold : LF.textSecondary)
            }
            .padding(14)
            .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var deleteClipButton: some View {
        Button {
            requestDeleteClip()
        } label: {
            Group {
                if isDeletingClip {
                    Label("正在删除…", systemImage: "hourglass")
                } else {
                    Label("删除素材", systemImage: "trash")
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isDeletingClip)
        .padding(.top, 2)
    }

    private func requestDeleteClip() {
        referencedWorkNames = appState.worksReferencingClip(clip.id).map(\.name)
        if referencedWorkNames.isEmpty {
            showDeleteConfirmation = true
        } else {
            showReferencedWorkAlert = true
        }
    }
}

/// 拖拽预览：小尺寸素材缩略图（长按拖到文件夹时用）
struct ClipDragPreview: View {
    let clip: SegmentedClip

    var body: some View {
        Group {
            ClipThumbnailView(clip: clip, index: 0, maxPixelSize: 88)
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(LF.gold, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

/// 应用 EXIF orientation：把 UIImage 重绘为像素方向正确的 CGImage
private extension UIImage {
    func fixedOrientation() -> CGImage? {
        guard imageOrientation != .up else { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let fixed = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return fixed.cgImage
    }
}
