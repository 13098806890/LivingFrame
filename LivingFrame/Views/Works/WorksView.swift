import LivingFrameCore
import SwiftUI

struct WorksView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showNewProjectConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if appState.isLoadingWorks {
                    ProgressView("正在加载作品…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if appState.works.isEmpty {
                    EmptyStateView(
                        icon: "photo.stack",
                        title: "还没有作品",
                        message: "在编辑页编辑内容，点击保存后作品会显示在这里"
                    )
                    .padding(.top, 80)
                } else {
                    let draftWorks = appState.works.filter { $0.draft != nil }
                    let savedWorks = appState.works.filter { $0.draft == nil }

                    LazyVStack(alignment: .leading, spacing: 18) {
                        worksSectionHeader(
                            title: "草稿箱",
                            subtitle: "自动保存的修改，点击继续编辑；正式作品不会被覆盖。",
                            icon: "pencil.circle.fill"
                        )
                        if !draftWorks.isEmpty {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(draftWorks) { work in
                                    WorkCell(work: work)
                                }
                            }
                        } else {
                            Text("暂无草稿。编辑已保存作品后的修改会自动出现在这里。")
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                                .padding(.horizontal, 4)
                        }

                        if !savedWorks.isEmpty {
                            worksSectionHeader(
                                title: "已保存作品",
                                subtitle: draftWorks.isEmpty ? nil : "手动保存的正式版本",
                                icon: "photo.stack"
                            )
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(savedWorks) { work in
                                    WorkCell(work: work)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .lfNavigationTitle("作品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        requestNewProject()
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                }
            }
            .confirmationDialog("开始新工程？", isPresented: $showNewProjectConfirmation, titleVisibility: .visible) {
                if appState.editingWorkID != nil {
                    Button("新建并保留草稿") {
                        Task { @MainActor in
                            guard await appState.saveCurrentDraftNow() else { return }
                            createNewProject()
                        }
                    }
                } else {
                    Button("放弃并新建", role: .destructive) {
                        createNewProject()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                if appState.editingWorkID != nil {
                    Text("当前修改尚未正式保存，继续新建会先将其保留为当前作品的草稿。")
                } else {
                    Text("当前工程尚未保存为作品，继续新建会丢失这些修改。")
                }
            }
        }
        .magicBackground()
    }

    private func worksSectionHeader(
        title: String,
        subtitle: String?,
        icon: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(LF.selectionText)
                .frame(width: 32, height: 32)
                .background(LF.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(LF.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private func requestNewProject() {
        if appState.hasUnsavedChanges {
            showNewProjectConfirmation = true
        } else {
            createNewProject()
        }
    }

    private func createNewProject() {
        appState.createComposition()
        appState.selectedTab = .editor
    }
}

private struct WorkCell: View {
    @EnvironmentObject private var appState: AppState
    @State private var showDeleteConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var pendingAction: WorkAction?
    let work: WorkItem

    private enum WorkAction {
        case edit
        case export
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = UIImage(data: work.posterData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 118)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Color.black
                    .frame(height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(work.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack {
                Text((work.draft?.updatedAt ?? work.lastSavedAt).formatted(date: .abbreviated, time: .omitted))
                Spacer()
                if work.draft != nil {
                    Label("有草稿", systemImage: "pencil.circle.fill")
                        .foregroundStyle(LF.header)
                } else {
                    Text("已保存")
                }
            }
            .font(.caption2)
            .foregroundStyle(LF.textSecondary)

            HStack(spacing: 8) {
                Button {
                    request(.edit)
                } label: {
                    Label("编辑", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(LF.textPrimary)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(8)
        .background(LF.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(LF.surface2, lineWidth: 1)
        }
        .contextMenu {
            Button {
                request(.edit)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button {
                request(.export)
            } label: {
                Label("重新导出", systemImage: "arrow.up.circle")
            }
            Button {
                renameText = work.name
                showRenameAlert = true
            } label: {
                Label("重命名", systemImage: "pencil.line")
            }
            Button {
                Task { _ = await appState.duplicateWork(work) }
            } label: {
                Label("复制作品", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .confirmationDialog("删除这个作品？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                appState.deleteWork(work)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，素材库中的素材不会被删除。")
        }
        .confirmationDialog("切换作品？", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            if appState.editingWorkID != nil {
                Button("切换并保留草稿") {
                    guard let pendingAction else { return }
                    Task { @MainActor in
                        guard await appState.saveCurrentDraftNow() else { return }
                        perform(pendingAction)
                    }
                }
            } else {
                Button("放弃并继续", role: .destructive) {
                    if let pendingAction {
                        perform(pendingAction)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if appState.editingWorkID != nil {
                Text("当前修改尚未正式保存，切换作品后会保留为草稿；正式作品仍需点击“保存”。")
            } else {
                Text("当前工程尚未保存为作品，切换后这些修改会丢失。")
            }
        }
        .alert("重命名作品", isPresented: $showRenameAlert) {
            TextField("作品名称", text: $renameText)
            Button("保存") {
                Task { await appState.renameWork(work, to: renameText) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func request(_ action: WorkAction) {
        if appState.hasUnsavedChanges && appState.editingWorkID != work.id {
            pendingAction = action
            showDiscardConfirmation = true
        } else {
            perform(action)
        }
    }

    private func perform(_ action: WorkAction) {
        appState.reopen(work)
        appState.selectedTab = .editor
        if case .export = action {
            Task { @MainActor in
                await Task.yield()
                appState.showExportView = true
            }
        }
    }
}
