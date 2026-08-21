import LivingFrameCore
import SwiftUI

/// 设为 Widget 画面：选作品 → 渲染首帧写入 App Group
struct WidgetSetupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var appliedWorkName: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                SectionCard(title: "说明") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Widget 无法播放视频或动图（WidgetKit 限制）", systemImage: "info.circle")
                        Text("我们展示作品的第一帧静态画面；点按 Widget 会打开 App 查看动态效果。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                    }
                }

                SectionCard(title: "当前 Widget 画面") {
                    HStack(spacing: 12) {
                        if let poster = FrameStore.loadPoster() {
                            Image(decorative: poster, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LF.surface2)
                                .frame(width: 56, height: 56)
                                .overlay {
                                    Image(systemName: "square.grid.2x2")
                                        .foregroundStyle(LF.textSecondary)
                                }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FrameStore.loadTitle() ?? "未设置")
                                .font(.subheadline.weight(.medium))
                            Text("长按桌面 → 添加小组件 → 活影")
                                .font(.caption2)
                                .foregroundStyle(LF.textSecondary)
                        }
                        Spacer()
                    }
                }

                SectionCard(title: "作品列表") {
                    if appState.works.isEmpty {
                        Text("暂无作品，请先在编辑页保存")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                    } else {
                        ForEach(appState.works) { work in
                            Button {
                                appState.savePosterForWidget(work)
                                appliedWorkName = work.name
                            } label: {
                                HStack {
                                    if let image = UIImage(data: work.posterData) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 40, height: 40)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(work.name)
                                            .font(.subheadline)
                                        Text(work.lastSavedAt.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption2)
                                            .foregroundStyle(LF.textSecondary)
                                    }
                                    Spacer()
                                    if appliedWorkName == work.name {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(LF.gold)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Widget 设置")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(LF.gold)
                }
            }
        }
    }
}
