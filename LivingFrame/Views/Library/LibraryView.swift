import AVFoundation
import AVKit
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
    /// 超过 1 分钟的视频，在动态提取前选择源视频范围。
    @State private var pendingVideoRange: PendingVideoRange?
    @State private var importTask: Task<Void, Never>?

    /// 待用户确认提取方式的素材（视频/Live 均先询问）
    private struct PendingExtract: Identifiable {
        let id = UUID()
        let name: String
        let source: ImportSource
        /// true = 动态贴纸，false = 静态贴纸，nil = 取消
        var resume: (Bool?) -> Void
    }

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
                                    url: url, name: name, stillOrientation: stillOrientation
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
                isDownloading = false
            }
        }
    }

    private enum ExtractKind {
        case live
        case `static`
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
            Text("本次最多处理 \(Int(appState.maxExtractionDuration)) 秒，超出部分从开头截取")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
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
                            // 单击 = 弹出操作菜单；拖拽从右上角把手开始。
                            ZStack(alignment: .topTrailing) {
                                ClipCell(clip: clip)
                                    .onTapGesture {
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
                    .tint(LF.accent)
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
                    Button("提取") {
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
            guard let self else { return }
            self.player.pause()
            self.player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
            self.isPlaying = false
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
                                .foregroundStyle(filed ? LF.destructive : LF.gold)
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
