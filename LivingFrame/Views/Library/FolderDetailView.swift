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
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    /// 单击素材弹出的操作菜单
    @State private var menuClip: SegmentedClip?
    /// 帧编辑（"编辑帧"入口）
    @State private var frameEditClip: SegmentedClip?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                childFoldersSection
                clipsSection
            }
            .padding()
        }
        .navigationTitle(folder.name)
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
            Text("将创建在「\(folder.name)」里面")
        }
        .sheet(isPresented: $showAddClips) {
            FolderAddClipsView(folder: folder)
                .environmentObject(appState)
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
                                        .foregroundStyle(LF.gold)
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

    /// 描边可选颜色
    private var edgeColorOptions: [(name: String, hex: String)] {
        [("白色", "FFFFFF"), ("黑色", "000000"), ("金色", "E8C05C"),
         ("红色", "E74C3C"), ("粉色", "FF9FF3"), ("蓝色", "54A0FF"),
         ("绿色", "1DD1A1"), ("紫色", "8B7CF6")]
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
        }
    }
}

/// 从全部素材中选择素材加入当前文件夹
private struct FolderAddClipsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let folder: LibraryFolder

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
                            Button {
                                appState.moveClip(clip.id, toFolder: folder.id)
                                dismiss()
                            } label: {
                                AssetCell(clip: clip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("添加素材")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
