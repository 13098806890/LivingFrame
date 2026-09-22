import LivingFrameCore
import SwiftUI

struct WorksView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showNewProjectConfirmation = false

    private let recentSavedWorkLimit = 6
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
                    // 自动保存只进入草稿箱；只有存在主动保存快照的条目才进入作品。
                    // 同一工程既有正式版本又有后续草稿时，两区分别展示各自版本。
                    let savedWorks = appState.works
                        .filter(\.hasSavedVersion)
                        .sorted { $0.worksListSavedDate > $1.worksListSavedDate }
                    let recentSavedWorks = Array(savedWorks.prefix(recentSavedWorkLimit))

                    LazyVStack(alignment: .leading, spacing: 18) {
                        worksSectionHeader(
                            title: "草稿箱",
                            subtitle: "自动保存的修改，点击继续编辑；正式作品不会被覆盖。",
                            icon: "pencil.circle.fill"
                        )
                        if !draftWorks.isEmpty {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(draftWorks) { work in
                                    WorkCell(work: work, version: .draft)
                                }
                            }
                        } else {
                            Text("暂无草稿。编辑中的内容会自动出现在这里，正式作品不会被覆盖。")
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                                .padding(.horizontal, 4)
                        }

                        if !savedWorks.isEmpty {
                            HStack(spacing: 8) {
                                worksSectionHeader(
                                    title: "已保存作品",
                                    subtitle: draftWorks.isEmpty ? nil : "手动保存的正式版本",
                                    icon: "photo.stack"
                                )

                                if savedWorks.count > recentSavedWorkLimit {
                                    NavigationLink {
                                        SavedWorksView()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text("查看全部")
                                            Image(systemName: "chevron.right")
                                                .font(.caption2.weight(.semibold))
                                        }
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(LF.actionPrimary)
                                        .fixedSize()
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(recentSavedWorks) { work in
                                    WorkCell(work: work, version: .saved)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("作品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        requestNewProject()
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline.weight(.semibold))
                    }
                    .tint(LF.actionPrimary)
                    .accessibilityLabel("新建")
                    .accessibilityIdentifier("works-create-project")
                }
            }
            .confirmationDialog("开始新工程？", isPresented: $showNewProjectConfirmation, titleVisibility: .visible) {
                Button("新建并保留草稿") {
                    Task { @MainActor in
                        guard await appState.saveCurrentDraftNow() else { return }
                        createNewProject()
                    }
                }
                Button("放弃并新建", role: .destructive) {
                    createNewProject()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前修改尚未正式保存，继续新建前会先将其保留为草稿。")
            }
        }
        .magicBackground()
    }

    private func worksSectionHeader(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey?,
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

private enum SavedWorksSortOption: String, CaseIterable, Identifiable {
    case recentlySaved
    case name

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .recentlySaved: "最近保存"
        case .name: "名称"
        }
    }
}

private struct SavedWorksView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var sortOption: SavedWorksSortOption = .recentlySaved
    @State private var displayedCount = 30

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    private var matchingWorks: [WorkItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = appState.works.filter { work in
            work.hasSavedVersion && (query.isEmpty || work.name.localizedCaseInsensitiveContains(query))
        }

        switch sortOption {
        case .recentlySaved:
            return results.sorted { $0.worksListSavedDate > $1.worksListSavedDate }
        case .name:
            return results.sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                if comparison == .orderedSame {
                    return $0.worksListSavedDate > $1.worksListSavedDate
                }
                return comparison == .orderedAscending
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if matchingWorks.isEmpty {
                    EmptyStateView(
                        icon: searchText.isEmpty ? "photo.stack" : "magnifyingglass",
                        title: searchText.isEmpty ? "还没有作品" : "没有匹配的作品",
                        message: searchText.isEmpty
                            ? "在编辑页编辑内容，点击保存后作品会显示在这里"
                            : "尝试其他关键词"
                    )
                    .padding(.top, 32)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(matchingWorks.prefix(displayedCount))) { work in
                            WorkCell(work: work, version: .saved)
                        }
                    }

                    if matchingWorks.count > displayedCount {
                        Button("加载更多") {
                            displayedCount += pageSize
                        }
                        .lfActionButtonStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                }
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("全部作品")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索作品名称")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序方式", selection: $sortOption) {
                        ForEach(SavedWorksSortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .onChange(of: searchText) { _, _ in
            displayedCount = pageSize
        }
        .onChange(of: sortOption) { _, _ in
            displayedCount = pageSize
        }
    }
}

private extension WorkItem {
    var worksListSavedDate: Date { savedAt ?? lastSavedAt }
}

private struct WorkCell: View {
    @EnvironmentObject private var appState: AppState
    @State private var showDeleteConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var pendingAction: WorkAction?
    @State private var workStorageBytes: Int64?
    let work: WorkItem
    let version: WorkVersion

    enum WorkVersion: Equatable {
        case draft
        case saved
    }

    private enum WorkAction {
        case edit
        case export
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                if let image = UIImage(data: displayedPosterData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 118)
                        .clipped()
                } else {
                    Color.black
                        .frame(maxWidth: .infinity)
                        .frame(height: 118)
                }

                HStack(alignment: .top) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .lfCircleIconButtonStyle(
                        diameter: 26,
                        iconSize: 11,
                        foregroundColor: LF.header,
                        backgroundColor: LF.header.opacity(0.16)
                    )
                    .accessibilityLabel("删除")
                    // 将确认框附着到实际删除按钮，避免在 iPad/大屏上以整张作品卡片为锚点。
                    .confirmationDialog("删除这个作品？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                        Button("删除", role: .destructive) {
                            appState.deleteWork(work)
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("删除后无法恢复，素材库中的素材不会被删除。")
                    }

                    Spacer(minLength: 0)

                    Button {
                        request(.edit)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .lfCircleIconButtonStyle(
                        diameter: 26,
                        iconSize: 11,
                        foregroundColor: LF.actionPrimary,
                        backgroundColor: LF.actionPrimary.opacity(0.16)
                    )
                    .accessibilityLabel("编辑")
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(displayedStorageSize)
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.62), in: Capsule())
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(work.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(displayedDate.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .confirmationDialog("切换作品？", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("切换并保留草稿") {
                guard let pendingAction else { return }
                Task { @MainActor in
                    guard await appState.saveCurrentDraftNow() else { return }
                    perform(pendingAction)
                }
            }
            Button("放弃并继续", role: .destructive) {
                if let pendingAction {
                    perform(pendingAction)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前修改尚未正式保存，切换作品前会先将其保留为草稿；正式作品仍需点击“保存”。")
        }
        .alert("重命名作品", isPresented: $showRenameAlert) {
            TextField("作品名称", text: $renameText)
            Button("保存") {
                Task { await appState.renameWork(work, to: renameText) }
            }
            Button("取消", role: .cancel) {}
        }
        .task(id: storageSizeTaskID) {
            workStorageBytes = nil
            let bytes = await appState.workStorageSizeBytes(for: work.id)
            guard !Task.isCancelled else { return }
            workStorageBytes = bytes
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
        appState.reopen(work, includingDraft: version == .draft)
        appState.selectedTab = .editor
        if case .export = action {
            Task { @MainActor in
                await Task.yield()
                appState.showExportView = true
            }
        }
    }

    private var displayedPosterData: Data {
        if version == .draft {
            return work.draft?.posterData ?? work.posterData
        }
        return work.posterData
    }

    private var displayedDate: Date {
        if version == .draft, let draftDate = work.draft?.updatedAt {
            return draftDate
        }
        return work.savedAt ?? work.lastSavedAt
    }

    private var displayedStorageSize: String {
        guard let workStorageBytes else { return NSLocalizedString("计算中…", comment: "Work storage size loading placeholder") }
        return ByteCountFormatter.string(fromByteCount: workStorageBytes, countStyle: .file)
    }

    private var storageSizeTaskID: String {
        [
            work.id.uuidString,
            String(work.updatedAt.timeIntervalSince1970),
            String(work.draft?.updatedAt.timeIntervalSince1970 ?? 0),
            String(work.posterData.count),
            String(work.draft?.posterData?.count ?? 0)
        ].joined(separator: ":")
    }
}
