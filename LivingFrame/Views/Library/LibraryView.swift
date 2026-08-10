import LivingFrameCore
import Photos
import PhotosUI
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var loadError: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    pickerSection
                    if appState.isSegmenting {
                        segmentationCard
                    }
                    clipsSection
                }
                .padding()
            }
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
            guard let item = items.first else { return }
            pickerItems.removeAll()
            load(item)
        }
    }

    private var loadErrorMessage: String? {
        loadError ?? appState.segmentationError
    }

    private func load(_ item: PhotosPickerItem) {
        Task {
            let types = item.supportedContentTypes
            LogStore.log("load: itemIdentifier=\(item.itemIdentifier ?? "nil") types=\(types.map(\.identifier))")
            // 1. Live Photo：从 PHAsset 取视频轨（需相册读取权限）
            if types.contains(where: { $0.conforms(to: .livePhoto) }) {
                if await loadLivePhotoVideo(item: item) { return }
                await MainActor.run {
                    loadError = NSLocalizedString("无法读取所选素材", comment: "Load failure detail")
                }
                return
            }
            // 2. 视频
            if types.contains(where: { $0.conforms(to: .movie) }),
               await loadMovie(item: item) { return }
            // 3. 普通照片：单帧抠图
            if types.contains(where: { $0.conforms(to: .image) }),
               await loadPhoto(item: item) { return }
            await MainActor.run {
                loadError = NSLocalizedString("无法读取所选素材", comment: "Load failure detail")
            }
        }
    }

    private func loadLivePhotoVideo(item: PhotosPickerItem) async -> Bool {
        guard let id = item.itemIdentifier else {
            LogStore.log("loadLivePhotoVideo: 无 itemIdentifier")
            return false
        }
        let status = await requestPhotoLibraryAccess()
        LogStore.log("loadLivePhotoVideo: 相册权限=\(status.rawValue)")
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            LogStore.log("loadLivePhotoVideo: PHAsset 获取失败")
            return false
        }
        let resources = PHAssetResource.assetResources(for: asset)
        LogStore.log("loadLivePhotoVideo: asset=\(asset.localIdentifier) mediaType=\(asset.mediaType.rawValue) resources=\(resources.map { "\($0.type.rawValue):\($0.originalFilename):\($0.value(forKey: "fileSize") ?? "?")" })")
        let options = PHVideoRequestOptions()
        options.deliveryMode = .fastFormat
        let result: (url: URL?, error: Error?)? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                continuation.resume(returning: (url: (avAsset as? AVURLAsset)?.url, error: info?[PHImageErrorKey] as? Error))
            }
        }
        guard let result, let url = result.url else {
            LogStore.log("loadLivePhotoVideo: requestAVAsset 失败 error=\(String(describing: result?.error))")
            return false
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        LogStore.log("loadLivePhotoVideo: 视频 URL=\(url.path) 大小=\(size) bytes")
        guard let copy = try? await copyToTemporaryFile(url) else {
            LogStore.log("loadLivePhotoVideo: 拷贝到临时目录失败")
            return false
        }
        LogStore.log("loadLivePhotoVideo: 已拷贝到 \(copy.path)")
        await MainActor.run {
            appState.startSegmenting(url: copy, name: copy.lastPathComponent)
        }
        return true
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

    private func loadMovie(item: PhotosPickerItem) async -> Bool {
        guard let movie = try? await item.loadTransferable(type: MovieFile.self) else {
            LogStore.log("loadMovie: MovieFile 加载失败")
            return false
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: movie.url.path)[.size] as? Int) ?? 0
        LogStore.log("loadMovie: URL=\(movie.url.path) 大小=\(size) bytes")
        await MainActor.run {
            appState.startSegmenting(url: movie.url, name: movie.url.lastPathComponent)
        }
        return true
    }

    private func loadPhoto(item: PhotosPickerItem) async -> Bool {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            LogStore.log("loadPhoto: Data 加载失败")
            return false
        }
        guard let image = UIImage(data: data),
              let fixed = image.fixedOrientation() else {
            LogStore.log("loadPhoto: UIImage 解码失败 data=\(data.count) bytes")
            return false
        }
        LogStore.log("loadPhoto: data=\(data.count) bytes 尺寸=\(image.size.width)x\(image.size.height) orientation=\(image.imageOrientation.rawValue)")
        await MainActor.run {
            appState.startPhotoSegmenting(
                cgImage: fixed,
                name: NSLocalizedString("照片", comment: "Photo clip name")
            )
        }
        return true
    }

    private func copyToTemporaryFile(_ url: URL) async throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    // MARK: - 抠图进度

    private var segmentationCard: some View {
        SectionCard(title: "正在抠图") {
            HStack {
                ProgressView(value: appState.segmentationProgress)
                    .tint(LF.gold)
                Text(String(format: NSLocalizedString("percent", comment: "Progress"), Int(appState.segmentationProgress * 100)))
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
        SectionCard(title: "已抠素材") {
            if appState.clips.isEmpty {
                EmptyStateView(
                    icon: "wand.and.stars",
                    title: "还没有素材",
                    message:                     "选择视频、Live Photo 或照片，\n人物会被自动抠出来"
                )
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(appState.clips) { clip in
                        ClipCell(clip: clip) {
                            appState.addElementFromClip(clip)
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
}

private struct ClipCell: View {
    let clip: SegmentedClip
    let onAdd: () -> Void

    @State private var frameIndex = 0
    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let frame = clip.loadFrame(index: frameIndex) {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.black
                }
                if clip.audioURL != nil {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(LF.gold)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(4)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
                Text(String(format: NSLocalizedString("clip.meta", comment: "Clip metadata"), clip.duration, clip.frameCount))
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onAdd()
            } label: {
                Label("加入画布", systemImage: "plus.circle")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(LF.gold)
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
                .appendingPathComponent(UUID().uuidString)
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
