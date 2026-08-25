import AVFoundation
import ImageIO
import LivingFrameCore
import Photos
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
    /// 单击素材弹出的操作菜单（nil = 不显示）
    @State private var menuClip: SegmentedClip?
    /// 帧编辑（素材库"编辑帧"）
    @State private var frameEditClip: SegmentedClip?
    /// 提取方式选择弹窗（静态贴纸 / 动态贴纸）
    @State private var pendingExtract: PendingExtract?
    @State private var importTask: Task<Void, Never>?

    /// 待用户确认提取方式的素材（视频/Live 均先询问）
    private struct PendingExtract: Identifiable {
        let id = UUID()
        let name: String
        let source: ImportSource
        /// true = 动态贴纸，false = 静态贴纸，nil = 取消
        var resume: (Bool?) -> Void
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                pickerSection
                foldersSection
                if isDownloading {
                    downloadCard
                }
                if appState.isSegmenting {
                    segmentationCard
                }
                clipsSection
            }
            .padding(.horizontal)
            .navigationTitle("素材库")
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 5,
                        matching: .any(of: [.videos, .livePhotos, .images])
                    ) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(LF.gold)
                    }
                }
            }
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
                Text("把抠好的素材分门别类收纳")
            }
            .alert(
                NSLocalizedString(
                    loadError != nil ? "导入失败" : "抠图失败",
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
            .confirmationDialog(
                "提取方式",
                isPresented: Binding(
                    get: { pendingExtract != nil },
                    set: { if !$0 { pendingExtract = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("动态贴纸（跟随画面变化）") {
                    pendingExtract?.resume(true)
                }
                Button("静态贴纸（单张）") {
                    pendingExtract?.resume(false)
                }
                Button("取消", role: .cancel) {
                    pendingExtract?.resume(nil)
                }
            } message: {
                Text(pendingExtract.map { "「\($0.name)」是视频/Live Photo，选择提取方式" } ?? "")
            }
            .overlay {
                if let clip = menuClip {
                    ClipMenuView(
                        clip: clip,
                        onClose: { menuClip = nil },
                        onEditFrames: { frameEditClip = clip }
                    )
                    .environmentObject(appState)
                    .transition(.opacity)
                }
            }
            .sheet(item: $frameEditClip) { clip in
                FrameGridView(clipID: clip.id)
                    .environmentObject(appState)
            }
            .onDisappear {
                importTask?.cancel()
            }
        }
    }

    // MARK: - 素材入口

    private var pickerSection: some View {
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
                    Text("自动抠出人物，生成透明素材，全程在设备端处理")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems.removeAll()
            importTask = Task { @MainActor in
                // 1. 并行下载所有选中素材（iCloud 下载可多线程加速）
                var sources: [ImportSource] = []
                isDownloading = true
                downloadProgress = nil
                await withTaskGroup(of: ImportSource?.self) { group in
                    for item in items {
                        group.addTask { await load(item) }
                    }
                    for await source in group {
                        if let source { sources.append(source) }
                    }
                }
                // 下载完成即隐藏下载进度条（抠图阶段由「正在抠图」卡片展示）
                isDownloading = false
                // 2. 串行提取：视频/Live 先询问 静态/动态，照片直接静态
                for source in sources {
                    guard !Task.isCancelled else { break }
                    switch source {
                    case .video(let url, let name, let stillOrientation, let stillURL):
                        // 视频类（Live Photo / 普通视频）：询问提取方式
                        let kind: ExtractKind? = await withCheckedContinuation { continuation in
                            pendingExtract = PendingExtract(name: name, source: source) { extractLive in
                                guard let extractLive else {
                                    continuation.resume(returning: nil)
                                    return
                                }
                                continuation.resume(returning: extractLive ? .live : .static)
                            }
                        }
                        pendingExtract = nil
                        guard let kind else { continue }
                        switch kind {
                        case .live:
                            await appState.startSegmenting(
                                url: url, name: name, stillOrientation: stillOrientation
                            )
                        case .static:
                            if let cgImage = await firstFrame(of: url, stillURL: stillURL) {
                                await appState.startPhotoSegmenting(cgImage: cgImage, name: name)
                            }
                        }
                    case .photo(let cgImage, let name):
                        await appState.startPhotoSegmenting(cgImage: cgImage, name: name)
                    }
                }
                isDownloading = false
            }
        }
    }

    private enum ExtractKind {
        case live
        case `static`
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
        if let source = await loadLivePhotoVideo(item: item) { return source }
        if let source = await loadLivePhotoTransfer(item: item) { return source }
        return nil
    }

    private func loadLivePhotoVideo(item: PhotosPickerItem) async -> ImportSource? {
        guard let id = item.itemIdentifier else {
            LogStore.log("loadLivePhotoVideo: no itemIdentifier, trying PHLivePhoto transfer")
            return nil
        }
        let status = await requestPhotoLibraryAccess()
        LogStore.log("loadLivePhotoVideo: photo library permission=\(status.rawValue)")
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            LogStore.log("loadLivePhotoVideo: PHAsset fetch failed")
            return nil
        }
        let resources = PHAssetResource.assetResources(for: asset)
        LogStore.log("loadLivePhotoVideo: asset=\(asset.localIdentifier) isLivePhoto=\(asset.mediaSubtypes.contains(.photoLive)) mediaType=\(asset.mediaType.rawValue) resources=\(resources.map { "\($0.type.rawValue):\($0.originalFilename):\($0.value(forKey: "fileSize") ?? "?")" })")
        // 仅处理真正的 Live Photo；普通视频/照片交给后续分支
        guard asset.mediaSubtypes.contains(.photoLive) else {
            LogStore.log("loadLivePhotoVideo: not a Live Photo")
            return nil
        }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress, _, _, _ in
            LogStore.log("loadLivePhotoVideo: iCloud video download progress=\(Int(progress * 100))%")
            Task { @MainActor in self.downloadProgress = progress }
        }
        let result: (url: URL?, error: Error?)? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                continuation.resume(returning: (url: (avAsset as? AVURLAsset)?.url, error: info?[PHImageErrorKey] as? Error))
            }
        }
        guard let result, let url = result.url else {
            LogStore.log("loadLivePhotoVideo: requestAVAsset failed error=\(String(describing: result?.error))")
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log("loadLivePhotoVideo: video URL=\(url.path) size=\(size) bytes")
        guard let copy = try? await copyToTemporaryFile(url) else {
            LogStore.log("loadLivePhotoVideo: copy to temp failed")
            return nil
        }
        LogStore.log("loadLivePhotoVideo: copied to \(copy.path)")
        // 以静态图 EXIF 朝向传给抠图管线（视频轨无旋转元数据时用于方向修正）
        let stillOrientation = await stillOrientation(for: asset)
        let name = resources.first?.originalFilename ?? copy.lastPathComponent
        // 配套静态图（Live Photo 静态贴纸提取源）：请求原图数据存临时文件
        let stillURL = await liveStillImageURL(for: asset)
        LogStore.log("loadLivePhotoVideo: stillURL=\(stillURL?.path ?? "nil")")
        return .video(url: copy, name: name, stillOrientation: stillOrientation, stillURL: stillURL)
    }

    /// 下载 Live Photo 配套静态图到临时文件（静态贴纸提取源）
    private func liveStillImageURL(for asset: PHAsset) async -> URL? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress, _, _, _ in
            LogStore.log("loadLivePhotoVideo: iCloud still download progress=\(Int(progress * 100))%")
            Task { @MainActor in self.downloadProgress = progress }
        }
        let result: (data: Data?, error: Error?)? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                continuation.resume(returning: (data: data, error: info?[PHImageErrorKey] as? Error))
            }
        }
        guard let data = result?.data, result?.error == nil else {
            LogStore.log("liveStillImageURL: failed error=\(String(describing: result?.error))")
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LF-still-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        do {
            try data.write(to: url)
            return url
        } catch {
            LogStore.log("liveStillImageURL: write failed error=\(error)")
            return nil
        }
    }

    /// 兜底路径：PHLivePhoto 传输 + 提取 pairedVideo（iCloud 素材 itemIdentifier/类型缺失时使用）
    private func loadLivePhotoTransfer(item: PhotosPickerItem) async -> ImportSource? {
        let livePhoto: PHLivePhoto?
        do {
            livePhoto = try await item.loadTransferable(type: PHLivePhoto.self)
        } catch {
            LogStore.log("loadLivePhotoTransfer: PHLivePhoto transfer failed error=\(error)")
            return nil
        }
        guard let livePhoto else {
            LogStore.log("loadLivePhotoTransfer: not a Live Photo")
            return nil
        }
        let resources = PHAssetResource.assetResources(for: livePhoto)
        LogStore.log("loadLivePhotoTransfer: resources=\(resources.map { "\($0.type.rawValue):\($0.originalFilename):\($0.value(forKey: "fileSize") ?? "?")" })")
        guard let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
            LogStore.log("loadLivePhotoTransfer: no pairedVideo resource")
            return nil
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress in
            LogStore.log("loadLivePhotoTransfer: iCloud video download progress=\(Int(progress * 100))%")
            Task { @MainActor in self.downloadProgress = progress }
        }
        let writeError: Error? = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(
                for: videoResource,
                toFile: destination,
                options: options
            ) { error in
                continuation.resume(returning: error)
            }
        }
        guard writeError == nil else {
            LogStore.log("loadLivePhotoTransfer: video write failed error=\(String(describing: writeError))")
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        LogStore.log("loadLivePhotoTransfer: video written \(destination.path) size=\(size) bytes")
        // 以配套静态图 EXIF 朝向传给抠图管线（视频轨无旋转元数据时用于方向修正）
        var stillOrientation = CGImagePropertyOrientation.up
        var stillURL: URL? = nil
        if let stillResource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) {
            let stillURLTmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(stillResource.uniformTypeIdentifier)
            let stillError: Error? = await withCheckedContinuation { continuation in
                PHAssetResourceManager.default().writeData(for: stillResource, toFile: stillURLTmp, options: options) { error in
                    continuation.resume(returning: error)
                }
            }
            if stillError == nil {
                stillURL = stillURLTmp
                if let exif = exifOrientation(of: stillURLTmp) {
                    stillOrientation = exif
                }
            }
        }
        return .video(url: destination, name: videoResource.originalFilename, stillOrientation: stillOrientation, stillURL: stillURL)
    }

    /// 从 PHAsset 读静态图 EXIF 朝向
    private func stillOrientation(for asset: PHAsset) async -> CGImagePropertyOrientation {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress, _, _, _ in
            Task { @MainActor in self.downloadProgress = progress }
        }
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { _, _, orientation, _ in
                continuation.resume(returning: orientation)
            }
        }
    }

    /// 从图片文件读 EXIF 朝向
    private func exifOrientation(of url: URL) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return nil }
        return orientation
    }

    private func requestPhotoLibraryAccess() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        default:
            return status
        }
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
                                        dragOverFolderID == folder.id ? LF.selectionSurface : LF.surface2,
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

    private var segmentationCard: some View {
        SectionCard(title: "正在抠图") {
            HStack {
                ProgressView(value: appState.segmentationProgress)
                    .tint(LF.gold)
                Text(String(format: "%d%%", Int(appState.segmentationProgress * 100)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LF.textSecondary)
            }
            Text(appState.segmentingName)
                .font(.caption)
                .foregroundStyle(LF.textSecondary)
                .lineLimit(1)
            Button("取消抠图", role: .cancel) {
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
                    message: "选择视频、Live Photo 或照片，\n人物会被自动抠出来"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(appState.clips) { clip in
                            // 单击 = 弹出操作菜单；长按（系统手势仲裁） = 拖拽到文件夹
                            ClipCell(clip: clip)
                                .onTapGesture {
                                    menuClip = clip
                                }
                                .draggable(clip.id) {
                                    ClipDragPreview(clip: clip)
                                }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

struct ClipCell: View {
    let clip: SegmentedClip
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                AnimatedClipPreview(clip: clip, maxPixelSize: 320, isPlaying: $isPlaying)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                ClipPreviewPlayButton(clip: clip, isPlaying: $isPlaying)
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
        }
    }
}

/// 素材操作菜单浮层：单击素材时弹出（边缘样式 / 描边参数 / 移动到文件夹 / 删除）
/// 文件夹列表：素材已在的文件夹显示减号（点击移出），不在的显示加号（点击加入）
struct ClipMenuView: View {
    @EnvironmentObject private var appState: AppState
    let clip: SegmentedClip
    let onClose: () -> Void
    /// 编辑帧入口回调（素材库弹出帧编辑页）
    var onEditFrames: () -> Void = {}

    private let colors: [(name: String, hex: String)] = [
        ("白", "FFFFFF"), ("黑", "000000"), ("灰", "B8BDC9"), ("金", "E8C05C"),
        ("红", "E74C3C"), ("粉", "FF9FF3"), ("蓝", "54A0FF"),
        ("绿", "1DD1A1"), ("紫", "8B7CF6")
    ]

    /// 素材是否已在指定文件夹
    private func isFiled(_ folderID: String) -> Bool {
        appState.folders.contains { $0.id == folderID && $0.clipIDs.contains(clip.id) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(spacing: 12) {
                // 边缘样式
                HStack(spacing: 8) {
                    ForEach(ClipEdgeStyle.displayCases) { style in
                        Button {
                            appState.setClipEdgeStyle(clip.id, style)
                            onClose()
                        } label: {
                            Text(style.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(clip.edgeStyle == style ? LF.gold : LF.surface2, in: Capsule())
                                .foregroundStyle(clip.edgeStyle == style ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // 描边参数（粗细 / 颜色）
                if clip.edgeStyle.isOutline {
                    HStack(spacing: 8) {
                        ForEach(EdgeThickness.allCases) { thickness in
                            Button {
                                appState.setClipEdgeThickness(clip.id, thickness)
                            } label: {
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
                    HStack(spacing: 10) {
                        ForEach(colors, id: \.hex) { color in
                            Button {
                                appState.setClipEdgeColor(clip.id, color.hex)
                            } label: {
                                Circle()
                                    .fill(Color(hex: color.hex))
                                    .frame(width: 24, height: 24)
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
                Divider()
                // 编辑帧（取舍帧序）
                Button {
                    onEditFrames()
                    onClose()
                } label: {
                    HStack {
                        Image(systemName: "square.grid.3x3")
                            .foregroundStyle(LF.gold)
                        Text("编辑帧")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LF.textPrimary)
                        Spacer()
                        Text("取舍帧，加速播放")
                            .font(.caption2)
                            .foregroundStyle(LF.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(LF.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                Divider()
                // 移动到文件夹（加减号切换）
                VStack(spacing: 6) {
                    ForEach(appState.folders) { folder in
                        let filed = isFiled(folder.id)
                        Button {
                            appState.moveClip(clip.id, toFolder: filed ? nil : folder.id)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(LF.folderIcon)
                                Text(folder.name)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(folder.clipIDs.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(LF.textSecondary)
                                Image(systemName: filed ? "minus.circle.fill" : "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(filed ? Color.red : LF.gold)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(LF.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    appState.deleteClip(clip.id)
                    onClose()
                } label: {
                    Label("删除素材", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LF.surface2, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.horizontal, 36)
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

/// 视频文件的 Transferable 包装（PhotosPicker 加载到本地临时文件）
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("LF-import-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
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
