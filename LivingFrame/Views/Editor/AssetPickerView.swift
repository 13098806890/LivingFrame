import Combine
import LivingFrameCore
import SwiftUI

/// 编辑页素材选择器：从素材库文件夹中选择素材（可多选）加入画布
struct AssetPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []
    /// 当前浏览的文件夹（nil = 全部素材），按钮直接切换，不依赖 NavigationLink
    @State private var folderID: String?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    private var currentFolder: LibraryFolder? {
        appState.folders.first { $0.id == folderID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    folderBar
                    if let folder = currentFolder, !appState.childFolders(of: folder.id).isEmpty {
                        childFolderBar(folder)
                    }
                    clipsGrid
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
                        for clipID in selectedIDs {
                            appState.addElementFromClipID(clipID)
                        }
                        dismiss()
                    } label: {
                        Text(selectedIDs.isEmpty ? "添加" : "添加(\(selectedIDs.count))")
                            .fontWeight(.semibold)
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
}

/// 动态素材预览：默认停在第一帧，点击左下角按钮后按素材帧率播放一次。
/// 播放状态独立于素材选择状态，避免点击播放时误触选中素材。
struct AnimatedClipPreview: View {
    let clip: SegmentedClip
    let maxPixelSize: CGFloat
    @State private var isPlaying = false
    @State private var framePosition = 0
    /// 点击播放后一次性加载的小尺寸帧；播放期间只切换内存中的 CGImage，避免每帧重复解码。
    @State private var decodedFrames: [CGImage] = []
    @State private var playbackRequest = 0

    private var activeFrames: [Int] {
        clip.activeFrameIndices
    }

    private var playbackFrames: [Int] {
        // 如果旧素材的排除帧记录异常，仍回退到磁盘上的完整帧序列，保证动态素材可播放。
        activeFrames.count > 1 ? activeFrames : Array(0..<max(clip.frameCount, 1))
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

            if isDynamic {
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            togglePlayback()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(.black.opacity(0.58), in: Circle())
                                .overlay {
                                    Circle()
                                        .stroke(.white.opacity(0.35), lineWidth: 0.8)
                                }
                        }
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel(isPlaying ? "暂停动态素材" : "播放动态素材")
                        Spacer()
                    }
                    .padding(6)
                }
            }
        }
        .task(id: playbackRequest) {
            await playOnceIfNeeded()
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
    }

    private func togglePlayback() {
        if isPlaying {
            isPlaying = false
            framePosition = 0
        } else {
            framePosition = 0
            isPlaying = true
        }
        playbackRequest &+= 1
    }

    private func playOnceIfNeeded() async {
        guard isPlaying, isDynamic else { return }

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

struct AssetCell: View {
    let clip: SegmentedClip
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            AnimatedClipPreview(clip: clip, maxPixelSize: 320)
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
