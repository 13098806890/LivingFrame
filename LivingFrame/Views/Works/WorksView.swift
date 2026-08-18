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
                        message: "编辑完成后导出，作品会自动保存到这里"
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
    let work: WorkItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = UIImage(data: work.posterData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
            Text(work.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack {
                Text(work.createdAt.formatted(date: .abbreviated, time: .omitted))
                Spacer()
                Text(work.format == .gif ? "GIF" : "MOV")
            }
            .font(.caption2)
            .foregroundStyle(LF.textSecondary)
        }
        .frame(height: 190)
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
                Label("重新编辑", systemImage: "pencil")
            }
            Button {
                appState.composition = work.composition
                appState.savePosterForWidget()
            } label: {
                Label("设为 Widget 画面", systemImage: "square.grid.2x2")
            }
            Button(role: .destructive) {
                appState.deleteWork(work)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .onTapGesture {
            appState.reopen(work)
            appState.selectedTab = .editor
        }
    }
}
