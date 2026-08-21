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
                            Text("480p（最快）").tag(854.0)
                            Text("720p（快）").tag(1280.0)
                            Text("1080p（慢，更精细）").tag(1920.0)
                        }
                        Picker("处理帧率", selection: $appState.processingFPS) {
                            Text("10 fps（最快）").tag(10.0)
                            Text("15 fps（快）").tag(15.0)
                            Text("30 fps（流畅）").tag(30.0)
                        }
                        Text("分辨率越高、帧率越高，抠图越精细，处理时间越长。素材越多，磁盘占用越大。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                    }

                    SectionCard(title: "存储") {
                        HStack {
                            Text("素材占用")
                            Spacer()
                            Text(appState.cacheSizeText)
                                .foregroundStyle(LF.textSecondary)
                        }
                        Text("清理临时文件不会删除任何素材（含文件夹内外的所有抠图结果）。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                        Button(role: .destructive) {
                            appState.clearCache()
                        } label: {
                            Label("清理临时文件", systemImage: "trash")
                        }
                    }

                    SectionCard(title: "调试日志") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(logSummary)
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                            HStack(spacing: 10) {
                                ShareLink(item: LogStore.logURL) {
                                    Label("导出日志 (txt)", systemImage: "square.and.arrow.up")
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
                            Text(appVersionText)
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

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "未设置"
        let build = info["CFBundleVersion"] as? String ?? "未设置"
        return "版本 \(version) (Build \(build))"
    }
}
