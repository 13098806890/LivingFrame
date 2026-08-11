import AVFoundation
import ImageIO
import LivingFrameCore
import Photos
import PhotosUI
import SwiftUI

/// 素材库浏览范围
enum LibraryScope: Hashable {
    case all
    case unfiled
    case folder(String)
}

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
            Task {
                isDownloading = true
                downloadProgress = nil
                defer { isDownloading = false }
                // 1. 并行下载所有选中素材（iCloud 下载可多线程加速）
                var sources: [ImportSource] = []
                await withTaskGroup(of: ImportSource?.self) { group in
                    for item in items {
                        group.addTask { await load(item) }
                    }
                    for await source in group {
                        if let source { sources.append(source) }
                    }
                }
                // 2. 串行抠图：一次一个素材，进度条不互相干扰，抠完一张显示一张
                for source in sources {
                    switch source {
                    case .video(let url, let name, let stillOrientation):
                        await appState.startSegmenting(
                            url: url, name: name, stillOrientation: stillOrientation
                        )
                    case .photo(let cgImage, let name):
                        await appState.startPhotoSegmenting(cgImage: cgImage, name: name)
                    }
                }
            }
        }
    }

    private var loadErrorMessage: String? {
        loadError ?? appState.segmentationError
    }

    /// 下载完成的待抠图素材（下载与抠图分离：下载并行，抠图串行）
    private enum ImportSource {
        case video(url: URL, name: String, stillOrientation: CGImagePropertyOrientation)
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
        return .video(url: copy, name: name, stillOrientation: stillOrientation)
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
        if let stillResource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) {
            let stillURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(stillResource.uniformTypeIdentifier)
            let stillError: Error? = await withCheckedContinuation { continuation in
                PHAssetResourceManager.default().writeData(for: stillResource, toFile: stillURL, options: options) { error in
                    continuation.resume(returning: error)
                }
            }
            if stillError == nil, let exif = exifOrientation(of: stillURL) {
                stillOrientation = exif
            }
        }
        return .video(url: destination, name: videoResource.originalFilename, stillOrientation: stillOrientation)
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
        return .video(url: movie.url, name: movie.url.lastPathComponent, stillOrientation: .up)
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
                                            .font(.title3)
                                            .foregroundStyle(dragOverFolderID == folder.id ? .black : LF.gold)
                                        Text(folder.name)
                                            .lineLimit(1)
                                        Text("\(folder.clipIDs.count)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(dragOverFolderID == folder.id ? .black.opacity(0.6) : LF.textSecondary)
                                        if appState.hasChildFolders(folder.id) {
                                            Image(systemName: "chevron.right")
                                                .font(.caption2)
                                                .foregroundStyle(dragOverFolderID == folder.id ? .black.opacity(0.5) : LF.textSecondary)
                                        }
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(
                                        dragOverFolderID == folder.id ? LF.gold : LF.surface2,
                                        in: Capsule()
                                    )
                                    .foregroundStyle(dragOverFolderID == folder.id ? .black : LF.textPrimary)
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
                            ClipCell(clip: clip)
                            // 长按拖动到文件夹
                            .draggable(clip.id)
                            .contextMenu {
                                Menu {
                                    ForEach(ClipEdgeStyle.allCases) { style in

                                        Button {
                                            appState.setClipEdgeStyle(clip.id, style)
                                        } label: {
                                            if clip.edgeStyle == style {
                                                Label(style.title, systemImage: "checkmark")
                                            } else {
                                                Text(style.title)
                                            }
                                        }
                                    }
                                } label: {
                                    Label("添加边缘", systemImage: "square.dashed")
                                }
                                Menu("移动到文件夹") {
                                    if isClipFiled(clip.id) {
                                        Button("移出文件夹") {
                                            appState.moveClip(clip.id, toFolder: nil)
                                        }
                                    }
                                    ForEach(appState.folders) { folder in
                                        Button(folder.name) {
                                            appState.moveClip(clip.id, toFolder: folder.id)
                                        }
                                    }
                                }
                                Button(role: .destructive) {
                                    appState.deleteClip(clip.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func isClipFiled(_ clipID: String) -> Bool {
        appState.folders.contains { $0.clipIDs.contains(clipID) }
    }
}

struct ClipCell: View {
    let clip: SegmentedClip

    @State private var frameIndex = 0
    private let timer = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                CheckerboardView()
                if let frame = FrameCache.shared.cachedThumbnail(for: clip, index: frameIndex, maxPixelSize: 480) {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.black
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if clip.audioURL != nil {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(LF.gold)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
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
            .onReceive(timer) { _ in
                guard clip.frameCount > 1 else { return }
                frameIndex = (frameIndex + 1) % clip.frameCount
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(clip.width)×\(clip.height) · \(Int(clip.fps.rounded()))fps · \(clip.frameCount)帧")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: FrameCache.shared.clipSizeBytes(clip), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
