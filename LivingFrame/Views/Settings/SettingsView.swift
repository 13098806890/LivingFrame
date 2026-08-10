import LivingFrameCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var logRefresh = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    SectionCard(title: "导出") {
                        Picker("默认格式", selection: $appState.defaultFormat) {
                            ForEach(ExportFormat.allCases) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        Picker("默认帧率", selection: $appState.exportFPS) {
                            Text("15 fps").tag(15.0)
                            Text("30 fps").tag(30.0)
                        }
                    }

                    SectionCard(title: "抠图") {
                        Picker("处理分辨率", selection: $appState.maxDimension) {
                            Text("720p（快）").tag(1280.0)
                            Text("1080p（慢，更精细）").tag(1920.0)
                        }
                        Text("分辨率越高越精细，处理时间越长。素材越多，磁盘占用越大。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                    }

                    SectionCard(title: "存储") {
                        HStack {
                            Text("素材缓存")
                            Spacer()
                            Text(appState.cacheSizeText)
                                .foregroundStyle(LF.textSecondary)
                        }
                        Button(role: .destructive) {
                            appState.clearCache()
                        } label: {
                            Label("清空缓存", systemImage: "trash")
                        }
                    }

                    SectionCard(title: "调试日志") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(logSummary)
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                            HStack(spacing: 10) {
                                ShareLink(item: LogStore.read()) {
                                    Label("导出日志", systemImage: "square.and.arrow.up")
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(MagicButtonStyle(prominent: false))
                                Button(role: .destructive) {
                                    LogStore.clear()
                                    logRefresh += 1
                                } label: {
                                    Label("清空", systemImage: "trash")
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(MagicButtonStyle(prominent: false))
                            }
                        }
                    }
                    .id(logRefresh)

                    SectionCard(title: "隐私") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("全部在设备端处理", systemImage: "lock.shield")
                                .font(.subheadline.weight(.medium))
                            Text("抠图、渲染、导出均在本机完成，不上传任何照片或视频，无需联网、无需账号。")
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                        }
                    }

                    SectionCard(title: "关于") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("活影 LivingFrame")
                                .font(.headline)
                            Text("哈利波特风格动态照片制作工具")
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                            Text("版本 1.0")
                                .font(.caption2)
                                .foregroundStyle(LF.textSecondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("设置")
            .magicBackground()
        }
    }

    private var logSummary: String {
        let log = LogStore.read()
        let lines = log.split(separator: "\n").count
        let size = (try? FileManager.default.attributesOfItem(
            atPath: LogStore.logURL.path
        )[.size] as? Int) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "共 \(lines) 行 · \(sizeText)\n选择素材后会自动记录加载与抠图过程，导出后可直接分析。"
    }
}
