import LivingFrameCore
import SwiftUI

/// 素材管理页：展示某个文件夹内的素材，支持移出/移动、边缘效果、删除、
/// 从全部素材中添加、新建子文件夹（归入同一级文件夹）
struct FolderDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let folder: LibraryFolder

    @State private var showDeleteFolderConfirm = false
    @State private var showAddClips = false
    @State private var showRemoveClips = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    /// 单击素材打开的详情页
    @State private var menuClip: SegmentedClip?
    @State private var clipDeletionAlert: FolderClipDeletionAlert?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                childFoldersSection
                clipsSection
            }
            .padding()
        }
        .lfNavigationTitle(verbatim: folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .magicBackground()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showNewFolderAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showRemoveClips = true
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(folderClips.isEmpty)
                .accessibilityLabel("从文件夹移除素材")

                Button {
                    showAddClips = true
                } label: {
                    Image(systemName: "plus")
                }
                Button(role: .destructive) {
                    showDeleteFolderConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            NSLocalizedString("删除文件夹", comment: "Delete folder"),
            isPresented: $showDeleteFolderConfirm,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除（素材保留）", comment: "Delete folder"), role: .destructive) {
                appState.deleteFolder(folder)
                dismiss()
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("文件夹及其子文件夹会被移除，素材保留在素材库", comment: "Delete folder message"))
        }
        .alert("新建文件夹", isPresented: $showNewFolderAlert) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") {
                appState.createFolder(named: newFolderName, inParent: folder.id)
                newFolderName = ""
            }
            Button("取消", role: .cancel) {
                newFolderName = ""
            }
        } message: {
            Text(String.localizedStringWithFormat(
                NSLocalizedString("将创建在「%1$@」里面", comment: "New subfolder parent context"),
                folder.name as NSString
            ))
        }
        .sheet(isPresented: $showAddClips) {
            FolderAddClipsView(folder: folder)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showRemoveClips) {
            FolderRemoveClipsView(folder: folder)
                .environmentObject(appState)
        }
        .fullScreenCover(item: $menuClip) { clip in
            ClipMenuView(
                clip: clip,
                onClose: { menuClip = nil }
            )
            .environmentObject(appState)
        }
    }

    /// 子文件夹（可继续进入，形成树状结构）
    private var childFoldersSection: some View {
        let children = appState.childFolders(of: folder.id)
        return VStack(alignment: .leading, spacing: 10) {
            if !children.isEmpty {
                Text("子文件夹")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)
                    .textCase(.uppercase)
                    .tracking(1.2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(children) { child in
                            NavigationLink {
                                FolderDetailView(folder: child)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3)
                                        .foregroundStyle(LF.folderIcon)
                                    Text(child.name)
                                        .lineLimit(1)
                                    Text("\(child.clipIDs.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(LF.textSecondary)
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(LF.surface2, in: Capsule())
                                .foregroundStyle(LF.textPrimary)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    appState.deleteFolder(child)
                                } label: {
                                    Label(NSLocalizedString("删除文件夹", comment: "Delete folder"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 实时读取文件夹（值传递的 folder 不会随 appState 更新）
    private var liveFolder: LibraryFolder? {
        appState.folders.first(where: { $0.id == folder.id })
    }

    private var folderClips: [SegmentedClip] {
        guard let liveFolder else { return [] }
        return liveFolder.clipIDs.compactMap { clipID in
            appState.clips.first(where: { $0.id == clipID })
        }
    }

    private var clipsSection: some View {
        SectionCard(title: "素材管理") {
            if folderClips.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "文件夹是空的",
                    message: "点击右上角「+」从全部素材中添加"
                )
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(folderClips) { clip in
                        ClipCell(
                            clip: clip,
                            onOpen: { menuClip = clip },
                            onDelete: { requestClipDeletion(clip) },
                            deleteAccessibilityLabel: "删除素材",
                            deleteAccessibilityIdentifier: "folder-delete-clip-\(clip.id)"
                        )
                    }
                }
            }
        }
        .alert(item: $clipDeletionAlert) { request in
            switch request.kind {
            case .confirm:
                return Alert(
                    title: Text("删除素材？"),
                    message: Text("删除后无法恢复。"),
                    primaryButton: .destructive(Text("删除")) {
                        appState.deleteClip(request.clip.id)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .referenced:
                return Alert(
                    title: Text("素材正在使用中"),
                    message: Text(String.localizedStringWithFormat(
                        NSLocalizedString("请先从以下作品中移除它，再删除素材：\n%1$@", comment: "Asset is used by these works"),
                        request.referencedWorkNames.joined(separator: "、") as NSString
                    )),
                    dismissButton: .cancel(Text("知道了"))
                )
            }
        }
    }

    private func requestClipDeletion(_ clip: SegmentedClip) {
        let workNames = appState.worksReferencingClip(clip.id).map(\.name)
        clipDeletionAlert = FolderClipDeletionAlert(
            clip: clip,
            kind: workNames.isEmpty ? .confirm : .referenced,
            referencedWorkNames: workNames
        )
    }
}

private struct FolderClipDeletionAlert: Identifiable {
    enum Kind {
        case confirm
        case referenced
    }

    let clip: SegmentedClip
    let kind: Kind
    let referencedWorkNames: [String]

    var id: String {
        switch kind {
        case .confirm: "\(clip.id)-confirm-delete"
        case .referenced: "\(clip.id)-delete-blocked"
        }
    }
}

/// 从全部素材中选择素材加入当前文件夹
private struct FolderAddClipsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let folder: LibraryFolder
    @State private var selectedClipIDs: [String] = []

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    /// 全部素材中尚未加入当前文件夹的
    private var candidates: [SegmentedClip] {
        let existing = Set(folder.clipIDs)
        return appState.clips.filter { !existing.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if candidates.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "没有可添加的素材",
                        message: "所有素材都已在这个文件夹里"
                    )
                    .padding()
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(candidates) { clip in
                            FolderCandidateCell(
                                clip: clip,
                                isSelected: selectedClipIDs.contains(clip.id)
                            ) {
                                toggleSelection(for: clip)
                            }
                        }
                    }
                    .padding()
                }
            }
            .lfNavigationTitle("添加素材")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        for clipID in selectedClipIDs where candidates.contains(where: { $0.id == clipID }) {
                            appState.moveClip(clipID, toFolder: folder.id)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedClipIDs.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggleSelection(for clip: SegmentedClip) {
        if let index = selectedClipIDs.firstIndex(of: clip.id) {
            selectedClipIDs.remove(at: index)
        } else {
            selectedClipIDs.append(clip.id)
        }
    }
}

/// 多选当前文件夹中的素材并批量移除归属；素材文件本身会保留。
private struct FolderRemoveClipsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let folder: LibraryFolder
    @State private var selectedClipIDs: [String] = []

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    private var candidates: [SegmentedClip] {
        guard let currentFolder = appState.folders.first(where: { $0.id == folder.id }) else { return [] }
        return currentFolder.clipIDs.compactMap { clipID in
            appState.clips.first(where: { $0.id == clipID })
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if candidates.isEmpty {
                    EmptyStateView(
                        icon: "folder",
                        title: "文件夹是空的",
                        message: "当前没有可移除的素材"
                    )
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        Text("仅从当前文件夹移除，素材仍保留在素材库中")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(candidates) { clip in
                                FolderCandidateCell(
                                    clip: clip,
                                    isSelected: selectedClipIDs.contains(clip.id)
                                ) {
                                    toggleSelection(for: clip)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .lfNavigationTitle("移除素材")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        for clipID in selectedClipIDs where candidates.contains(where: { $0.id == clipID }) {
                            appState.removeClip(clipID, fromFolder: folder.id)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedClipIDs.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggleSelection(for clip: SegmentedClip) {
        if let index = selectedClipIDs.firstIndex(of: clip.id) {
            selectedClipIDs.remove(at: index)
        } else {
            selectedClipIDs.append(clip.id)
        }
    }
}

private struct FolderCandidateCell: View {
    let clip: SegmentedClip
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 4) {
            AnimatedClipPreview(
                clip: clip,
                maxPixelSize: FrameCache.previewThumbnailMaxPixelSize,
                isPlaying: $isPlaying
            )
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                ClipPreviewPlayButton(clip: clip, isPlaying: $isPlaying)
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(LF.gold)
                        .background(.black.opacity(0.38), in: Circle())
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? LF.gold : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            Text(clip.name)
                .font(.caption2)
                .foregroundStyle(LF.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.name)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }
}
