import LivingFrameCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var logRefresh = 0
    @State private var isClearingLogs = false
    @State private var showAdvancedExportFormats = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    SectionCard(title: "外观") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("选择一套马卡龙皮肤，编辑器、素材库和检查器会同步更新。")
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)
                                ],
                                spacing: 10
                            ) {
                                ForEach(AppTheme.allCases) { theme in
                                    themeCard(theme)
                                }
                            }
                        }
                    }

                    SectionCard(title: "导出") {
                        if appState.defaultFormat == .gif {
                            Picker("默认格式", selection: $appState.defaultFormat) {
                                Text(ExportFormat.gif.title).tag(ExportFormat.gif)
                            }
                        } else {
                            HStack {
                                Text("默认格式")
                                Spacer()
                                Text(appState.defaultFormat.title)
                                    .foregroundStyle(LF.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Picker("默认帧率", selection: $appState.exportFPS) {
                            Text("15 fps").tag(15.0)
                            Text("30 fps").tag(30.0)
                            Text("60 fps").tag(60.0)
                        }

                        DisclosureGroup("高级导出格式", isExpanded: $showAdvancedExportFormats) {
                            Picker("默认格式", selection: $appState.defaultFormat) {
                                ForEach(ExportFormat.allCases.filter { $0 != .gif }) { format in
                                    Text(format.title).tag(format)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .tint(LF.header)
                    }

                    SectionCard(title: "人物素材") {
                        Picker("单个素材最长时长", selection: $appState.maxExtractionDuration) {
                            Text("3 秒").tag(3.0)
                            Text("5 秒（推荐）").tag(5.0)
                            Text("8 秒").tag(8.0)
                            Text("10 秒").tag(10.0)
                        }
                        Text("短视频默认从开头提取；超过 1 分钟的视频会先让你选择开始和结束位置。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)

                        Toggle("保留原始帧率和分辨率", isOn: $appState.preserveOriginalMediaQuality)
                            .tint(LF.actionPrimary)
                        Text("开启后按源素材实际帧率处理，并保留原始像素尺寸；处理帧率和处理分辨率预设将暂时不生效，处理时间和占用空间可能明显增加。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)

                        Picker("处理分辨率", selection: $appState.maxDimension) {
                            Text("480p（最快）").tag(854.0)
                            Text("720p（快）").tag(1280.0)
                            Text("1080p（慢，更精细）").tag(1920.0)
                        }
                        .disabled(appState.preserveOriginalMediaQuality)
                        Picker("处理帧率", selection: $appState.processingFPS) {
                            Text("10 fps（最快）").tag(10.0)
                            Text("15 fps（快）").tag(15.0)
                            Text("30 fps（流畅）").tag(30.0)
                            Text("60 fps（保留高帧率）").tag(60.0)
                        }
                        .disabled(appState.preserveOriginalMediaQuality)
                        Text(appState.preserveOriginalMediaQuality
                             ? "当前将按源素材实际帧率和原始尺寸处理，不会补帧或放大素材。"
                             : "仅当源素材帧率更高时才会保留更多帧，不会补帧。分辨率越高、帧率越高，人物素材越精细，处理时间越长。")
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
                        Text("清理临时文件不会删除任何素材（含文件夹内外的所有人物素材）。")
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
                                    guard !isClearingLogs else { return }
                                    isClearingLogs = true
                                    Task { @MainActor in
                                        await LogStore.clearAsync()
                                        isClearingLogs = false
                                        logRefresh += 1
                                    }
                                } label: {
                                    if isClearingLogs {
                                        ProgressView()
                                            .controlSize(.small)
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        Label("清空", systemImage: "trash")
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .disabled(isClearingLogs)
                                .buttonStyle(MagicButtonStyle(prominent: false))
                            }
                        }
                    }
                    .id(logRefresh)

                    SectionCard(title: "隐私") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("全部在设备端处理", systemImage: "lock.shield")
                                .font(.subheadline.weight(.medium))
                            Text("人物素材生成、渲染和导出均在本机完成，不上传任何照片或视频，无需联网、无需账号。")
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                        }
                    }

                    SectionCard(title: "关于") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GIFBloom")
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
            .lfNavigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
        .magicBackground()
        .task {
            showAdvancedExportFormats = appState.defaultFormat != .gif
            appState.refreshCacheSize()
        }
    }

    private func themeCard(_ theme: AppTheme) -> some View {
        let palette = theme.palette
        let isSelected = appState.appTheme == theme
        return Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                appState.appTheme = theme
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(
                        Array([
                            palette.brandTint,
                            palette.actionPrimary,
                            palette.accent,
                            palette.textPrimary,
                            palette.surface2
                        ].enumerated()),
                        id: \.offset
                    ) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 17, height: 17)
                            .overlay {
                                Circle().stroke(.white.opacity(0.7), lineWidth: 0.6)
                            }
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(palette.actionPrimary)
                    }
                }

                Text(theme.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.textPrimary)
                    .lineLimit(1)
                Text(theme.subtitle)
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(
                isSelected ? palette.selectionSurface : palette.surface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? palette.actionPrimary : palette.surface2.opacity(0.8),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .shadow(
                color: isSelected ? palette.actionPrimary.opacity(0.16) : .clear,
                radius: 7,
                y: 3
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityValue(isSelected ? "已选中" : "未选中")
    }

    private var logSummary: String {
        let log = LogStore.read()
        let lines = log.split(separator: "\n").count
        let size = (try? FileManager.default.attributesOfItem(
            atPath: LogStore.logURL.path
        )[.size] as? Int) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return String(
            format: NSLocalizedString("日志摘要", comment: "Log summary"),
            lines,
            sizeText
        )
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "未设置"
        let build = info["CFBundleVersion"] as? String ?? "未设置"
        return "版本 \(version) (Build \(build))"
    }
}
