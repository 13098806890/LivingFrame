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
                        Button {
                            if selectedIDs.contains(clip.id) {
                                selectedIDs.remove(clip.id)
                            } else {
                                selectedIDs.insert(clip.id)
                            }
                        } label: {
                            AssetCell(clip: clip)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: selectedIDs.contains(clip.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selectedIDs.contains(clip.id) ? LF.gold : LF.textSecondary.opacity(0.5))
                                        .padding(6)
                                }
                        }
                        .buttonStyle(.plain)
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

struct AssetCell: View {
    let clip: SegmentedClip

    @State private var frameIndex = 0
    private let timer = Timer.publish(every: 1.0 / 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                CheckerboardView()
                if let frame = FrameCache.shared.cachedThumbnail(for: clip, index: frameIndex, maxPixelSize: 320) {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.black
                }
            }
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onReceive(timer) { _ in
                guard clip.frameCount > 1 else { return }
                frameIndex = (frameIndex + 1) % clip.frameCount
            }

            Text(clip.name)
                .font(.caption2)
                .foregroundStyle(LF.textPrimary)
                .lineLimit(1)
        }
    }
}
