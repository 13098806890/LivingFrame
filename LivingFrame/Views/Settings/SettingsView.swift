import LivingFrameCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @State private var showAdvancedExportFormats = false
    @State private var showProStore = false
    @State private var showManageSubscription = false
    // Keep the switch's interaction state local to this view. SwiftUI's
    // environment-object binding can otherwise leave the UIKit accessibility
    // switch snapshot at 0 while AppState is being persisted synchronously.
    @State private var preserveOriginalMediaQuality = false

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

                    SectionCard(title: "剪影") {
                        Picker("单个素材最长时长", selection: $appState.maxExtractionDuration) {
                            Text("3 秒").tag(3.0)
                            Text("5 秒（推荐）").tag(5.0)
                            Text("8 秒").tag(8.0)
                            Text("10 秒").tag(10.0)
                        }
                        Text("超过单个素材最长时长的动态视频会先让你选择片段；未超出的默认从开头提取。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)

                        HStack(spacing: 12) {
                            // Keep the label as a separate control. SwiftUI's
                            // labelled Toggle exposes both a full-row
                            // accessibility Switch and a nested native
                            // UISwitch. XCTest can tap the former's label
                            // frame instead of the actual switch, leaving its
                            // value unchanged. The explicit label button and
                            // labelsHidden Toggle make the identifier/value
                            // belong to the real switch only.
                            Button {
                                preserveOriginalMediaQuality.toggle()
                            } label: {
                                Text("保留原始帧率和分辨率")
                                    .foregroundStyle(LF.textPrimary)
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)

                            Spacer(minLength: 8)

                            Toggle(
                                "保留原始帧率和分辨率",
                                isOn: Binding(
                                    get: { preserveOriginalMediaQuality },
                                    set: { preserveOriginalMediaQuality = $0 }
                                )
                            )
                            .labelsHidden()
                            .accessibilityLabel("保留原始帧率和分辨率")
                            .accessibilityIdentifier("settings-preserve-original-media-quality")
                            .tint(LF.actionPrimary)
                        }
                        Text("开启后按源素材实际帧率处理，并保留原始像素尺寸；处理帧率和处理分辨率预设将暂时不生效，处理时间和占用空间可能明显增加。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)

                        Picker("处理分辨率", selection: $appState.maxDimension) {
                            Text("480p（最快）").tag(854.0)
                            Text("720p（快）").tag(1280.0)
                            Text("1080p（慢，更精细）").tag(1920.0)
                        }
                        .accessibilityIdentifier("settings-processing-resolution")
                        .disabled(preserveOriginalMediaQuality)
                        Picker("处理帧率", selection: $appState.processingFPS) {
                            Text("10 fps（最快）").tag(10.0)
                            Text("15 fps（快）").tag(15.0)
                            Text("30 fps（流畅）").tag(30.0)
                            Text("60 fps（保留高帧率）").tag(60.0)
                        }
                        .accessibilityIdentifier("settings-processing-frame-rate")
                        .disabled(preserveOriginalMediaQuality)
                        Text(preserveOriginalMediaQuality
                             ? "当前将按源素材实际帧率和原始尺寸处理，不会补帧或放大素材。"
                             : "仅当源素材帧率更高时才会保留更多帧，不会补帧。分辨率越高、帧率越高，剪影边缘越精细，处理时间越长。")
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
                        Text("清理临时文件不会删除任何素材（含文件夹内外的所有剪影素材）。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                        Button(role: .destructive) {
                            appState.clearCache()
                        } label: {
                            Label("清理临时文件", systemImage: "trash")
                        }
                    }

                    SectionCard(title: "GIFBloom Pro") {
                        VStack(alignment: .leading, spacing: 10) {
                            if purchaseManager.hasPro {
                                Label("GIFBloom Pro 已解锁", systemImage: "checkmark.seal.fill")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(LF.actionPrimary)
                            } else {
                                Text("选择周订阅、年订阅或一次性买断解锁 GIFBloom Pro。")
                                    .font(.caption)
                                    .foregroundStyle(LF.textSecondary)
                            }

                            Button {
                                showProStore = true
                            } label: {
                                Label("订阅与买断", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(LF.actionPrimary)

                            if purchaseManager.hasActiveSubscription {
                                Button {
                                    showManageSubscription = true
                                } label: {
                                    Label("管理订阅", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(LF.actionPrimary)
                            }
                        }
                    }

                    SectionCard(title: "隐私") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("全部在设备端处理", systemImage: "lock.shield")
                                .font(.subheadline.weight(.medium))
                            Text("照片、视频、音频和工程均在设备本地处理，不上传到 GIFBloom 服务器。App Store 购买由 Apple 处理。")
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)

                            Link(destination: GIFBloomStoreLinks.privacyPolicy) {
                                Label("隐私政策", systemImage: "hand.raised")
                            }
                            Link(destination: GIFBloomStoreLinks.support) {
                                Label("支持", systemImage: "questionmark.circle")
                            }
                            Link(destination: GIFBloomStoreLinks.termsOfUse) {
                                Label("使用条款", systemImage: "doc.text")
                            }
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
                            Text(verbatim: "Adapted Twemoji artwork © Twitter, Inc. and contributors")
                                .font(.caption2)
                                .foregroundStyle(LF.textSecondary)
                            Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                                .font(.caption2)
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
            preserveOriginalMediaQuality = appState.preserveOriginalMediaQuality
            appState.refreshCacheSize()
        }
        .onChange(of: preserveOriginalMediaQuality) { _, value in
            appState.setPreserveOriginalMediaQuality(value)
        }
        .sheet(isPresented: $showProStore) {
            GIFBloomProStoreView()
        }
        .manageSubscriptionsSheet(
            isPresented: $showManageSubscription,
            subscriptionGroupID: PurchaseManager.subscriptionGroupID
        )
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
                            palette.folderIcon,
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

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "未设置"
        let build = info["CFBundleVersion"] as? String ?? "未设置"
        return String.localizedStringWithFormat(
            NSLocalizedString("版本 %1$@ (Build %2$@)", comment: "App version and build number"),
            version as NSString, build as NSString
        )
    }
}
