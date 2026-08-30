import LivingFrameCore
import SwiftUI

struct WorksView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showNewProjectConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if appState.works.isEmpty {
                    EmptyStateView(
                        icon: "photo.stack",
                        title: "还没有作品",
                        message: "在编辑页点击“保存”，作品会显示在这里"
                    )
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(appState.works) { work in
                            WorkCell(work: work)
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
            .confirmationDialog("放弃未保存修改？", isPresented: $showNewProjectConfirmation, titleVisibility: .visible) {
                Button("放弃并新建", role: .destructive) {
                    createNewProject()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前编辑内容尚未保存，继续新建会将其留在当前工程之外。")
            }
        }
        .magicBackground()
    }

    private func requestNewProject() {
        if appState.hasUnsavedChanges {
            showNewProjectConfirmation = true
        } else {
            createNewProject()
        }
    }

    private func createNewProject() {
        let aspect = appState.composition.map { CanvasAspect.aspect(for: $0.canvasRect.size) } ?? .landscape16x9
        appState.createComposition(aspect: aspect)
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
                Text(work.lastSavedAt.formatted(date: .abbreviated, time: .omitted))
                Spacer()
                Text("已保存")
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
                _ = appState.duplicateWork(work)
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
        .confirmationDialog("放弃未保存修改？", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃并继续", role: .destructive) {
                if let pendingAction {
                    perform(pendingAction)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前编辑内容尚未保存，切换作品后这些修改会丢失。")
        }
        .alert("重命名作品", isPresented: $showRenameAlert) {
            TextField("作品名称", text: $renameText)
            Button("保存") {
                appState.renameWork(work, to: renameText)
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
