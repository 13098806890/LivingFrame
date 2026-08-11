import LivingFrameCore
import SwiftUI

/// 编辑页素材选择器：从素材库文件夹中选择素材（可多选）加入画布
struct AssetPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var scope: LibraryScope = .all
    @State private var selectedIDs: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    folderBar
                    clipsGrid
                }
                .padding()
            }
            .navigationTitle("选择素材")
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

    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部素材", scope: .all)
                ForEach(appState.folders) { folder in
                    chip(folder.name, scope: .folder(folder.id))
                }
            }
        }
    }

    private func chip(_ title: String, scope: LibraryScope) -> some View {
        Button {
            self.scope = scope
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(self.scope == scope ? LF.gold : LF.surface2, in: Capsule())
                .foregroundStyle(self.scope == scope ? .black : LF.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private var scopedClips: [SegmentedClip] {
        switch scope {
        case .all:
            return appState.clips
        case .unfiled:
            let filedIDs = Set(appState.folders.flatMap(\.clipIDs))
            return appState.clips.filter { !filedIDs.contains($0.id) }
        case .folder(let folderID):
            guard let folder = appState.folders.first(where: { $0.id == folderID }) else { return [] }
            return folder.clipIDs.compactMap { clipID in
                appState.clips.first(where: { $0.id == clipID })
            }
        }
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
    private let timer = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                CheckerboardView()
                if let frame = FrameCache.shared.cachedThumbnail(for: clip, index: frameIndex, maxPixelSize: 360) {
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
