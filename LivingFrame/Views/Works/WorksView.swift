import LivingFrameCore
import SwiftUI

struct WorksView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showWidgetSetup = false

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
            .navigationTitle("作品")
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showWidgetSetup = true
                    } label: {
                        Label("Widget", systemImage: "square.grid.2x2")
                            .foregroundStyle(LF.gold)
                    }
                }
            }
            .sheet(isPresented: $showWidgetSetup) {
                WidgetSetupView()
                    .environmentObject(appState)
            }
        }
    }
}

private struct WorkCell: View {
    @EnvironmentObject private var appState: AppState
    @State private var showDeleteConfirmation = false
    let work: WorkItem

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
                    appState.reopen(work)
                    appState.selectedTab = .editor
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
                appState.reopen(work)
                appState.selectedTab = .editor
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button {
                appState.savePosterForWidget(work)
            } label: {
                Label("设为 Widget 画面", systemImage: "square.grid.2x2")
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
    }
}
