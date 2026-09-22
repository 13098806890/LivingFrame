import LivingFrameCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @State private var showProStore = false
    @State private var showManageSubscription = false
    // Keep the switch's interaction state local to this view. SwiftUI's
    // environment-object binding can otherwise leave the UIKit accessibility
    // switch snapshot at 0 while AppState is being persisted synchronously.
    @State private var preserveOriginalMediaQuality = false
    @State private var aboutLogoFirstFrame: CGImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    SectionCard(title: "导出") {
                        VStack(spacing: 0) {
                            settingsRow("默认格式") {
                                Picker("默认格式", selection: $appState.defaultFormat) {
                                    ForEach(ExportFormat.allCases) { format in
                                        Text(format.title)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.82)
                                            .tag(format)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .tint(LF.actionPrimary)
                            }

                            settingsDivider

                            settingsRow("默认帧率") {
                                Picker("默认帧率", selection: $appState.exportFPS) {
                                    Text("15 fps").tag(15.0)
                                    Text("30 fps").tag(30.0)
                                    Text("60 fps").tag(60.0)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .tint(LF.actionPrimary)
                            }
                        }

                    }

                    SectionCard(title: "剪影") {
                        VStack(spacing: 0) {
                            settingsRow("单个素材最长时长") {
                                Menu {
                                    extractionDurationOption(3)
                                    extractionDurationOption(5)
                                    if !purchaseManager.hasPro {
                                        Divider()
                                    }
                                    extractionDurationOption(10)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(extractionDurationLabel(for: selectedExtractionDuration))
                                        Image(systemName: "chevron.down")
                                            .font(.caption2.weight(.semibold))
                                    }
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(LF.actionPrimary)
                                }
                                .accessibilityLabel("单个素材最长时长")
                                .accessibilityValue(Text(extractionDurationLabel(for: selectedExtractionDuration)))
                            }
                        }
                        Text("超过单个素材最长时长的动态视频会先让你选择片段；未超出的默认从开头提取。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !purchaseManager.hasPro {
                            HStack(spacing: 10) {
                                Text("免费版最长 5 秒；GIFBloom Pro 可选 10 秒。")
                                    .font(.caption)
                                    .foregroundStyle(LF.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: 4)

                                Button("解锁更长片段") {
                                    showProStore = true
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LF.actionPrimary)
                                .fixedSize()
                            }
                            .padding(.top, 4)
                        }

                        settingsDivider

                        HStack(spacing: 12) {
                            // Keep the label as a separate control. SwiftUI's
                            // environment-object binding can otherwise leave the UIKit accessibility
                            // switch snapshot at 0 while AppState is being persisted synchronously.
                            Button {
                                preserveOriginalMediaQuality.toggle()
                            } label: {
                                Text("保留原始帧率和分辨率")
                                    .foregroundStyle(LF.textPrimary)
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

                        Text(preserveOriginalMediaQuality
                             ? "当前将按源素材实际帧率和原始尺寸处理，不会补帧或放大素材。"
                             : "仅当源素材帧率更高时才会保留更多帧，不会补帧。分辨率越高、帧率越高，剪影边缘越精细，处理时间越长。")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        settingsDivider

                        VStack(spacing: 0) {
                            settingsRow("处理分辨率") {
                                Picker("处理分辨率", selection: $appState.maxDimension) {
                                    Text(verbatim: "480p").tag(854.0)
                                    Text(verbatim: "720p").tag(1280.0)
                                    Text(verbatim: "1080p").tag(1920.0)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .tint(LF.actionPrimary)
                                .accessibilityIdentifier("settings-processing-resolution")
                            }
                            .disabled(preserveOriginalMediaQuality)

                            settingsDivider

                            settingsRow("处理帧率") {
                                Picker("处理帧率", selection: $appState.processingFPS) {
                                    Text(verbatim: "10 fps").tag(10.0)
                                    Text(verbatim: "15 fps").tag(15.0)
                                    Text(verbatim: "30 fps").tag(30.0)
                                    Text(verbatim: "60 fps").tag(60.0)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .tint(LF.actionPrimary)
                                .accessibilityIdentifier("settings-processing-frame-rate")
                            }
                            .disabled(preserveOriginalMediaQuality)
                        }
                    }

                    SectionCard(title: "GIFBloom Pro") {
                        VStack(alignment: .leading, spacing: 10) {
                            if purchaseManager.hasPro {
                                Label("GIFBloom Pro 已解锁", systemImage: "checkmark.seal.fill")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(LF.actionPrimary)
                            } else {
                                Text("选择周订阅或年订阅解锁 GIFBloom Pro。")
                                    .font(.caption)
                                    .foregroundStyle(LF.textSecondary)
                            }

                            if !purchaseManager.hasPro {
                                Button {
                                    showProStore = true
                                } label: {
                                    Text("订阅")
                                        .frame(maxWidth: .infinity)
                                }
                                .lfActionButtonStyle(.primary)
                            }

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

                    SectionCard(title: "关于") {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 3) {
                                if purchaseManager.hasPro {
                                    Image("GIFBloomProWordmark")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 144, height: 50, alignment: .leading)
                                        .accessibilityLabel("GIFBloom Pro")
                                } else if let aboutLogoFirstFrame {
                                    Image(decorative: aboutLogoFirstFrame, scale: 1)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 144, height: 50, alignment: .leading)
                                        .accessibilityLabel("GIFBloom")
                                } else {
                                    Text("GIFBloom")
                                        .font(.headline)
                                }
                            }

                            settingsDivider
                                .padding(.vertical, 14)

                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "lock.shield.fill")
                                    .foregroundStyle(LF.actionPrimary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("全部在设备端处理")
                                        .font(.subheadline.weight(.semibold))
                                    Text("照片、视频和工程均在设备本地处理，不上传到 GIFBloom 服务器。App Store 购买由 Apple 处理。")
                                        .font(.caption)
                                        .foregroundStyle(LF.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            settingsDivider
                                .padding(.vertical, 14)

                            VStack(spacing: 0) {
                                aboutLink("隐私政策", icon: "hand.raised", destination: GIFBloomStoreLinks.privacyPolicy)
                                settingsDivider
                                aboutLink("支持", icon: "questionmark.circle", destination: GIFBloomStoreLinks.support)
                                settingsDivider
                                aboutLink("使用条款", icon: "doc.text", destination: GIFBloomStoreLinks.termsOfUse)
                            }

                            settingsDivider
                                .padding(.top, 8)
                                .padding(.bottom, 10)

                            Text(appVersionText)
                                .font(.caption2)
                                .foregroundStyle(LF.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
        }
        .magicBackground()
        .task {
            preserveOriginalMediaQuality = appState.preserveOriginalMediaQuality
            if let firstAvailableLogo = DecorationRenderer.availableStickerCatalog.first(where: { $0.category == .logo }) {
                aboutLogoFirstFrame = DecorationRenderer().previewImage(for: firstAvailableLogo.id)
            }
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

    private var settingsDivider: some View {
        Divider()
            .overlay(LF.surface2.opacity(0.8))
    }

    private var selectedExtractionDuration: Double {
        purchaseManager.allowedExtractionDuration(
            configuredDuration: appState.maxExtractionDuration
        )
    }

    private func extractionDurationOption(_ duration: Double) -> some View {
        let isLocked = duration > PurchaseManager.freeMaximumExtractionDuration && !purchaseManager.hasPro
        let isSelected = abs(selectedExtractionDuration - duration) < 0.001

        return Button {
            if isLocked {
                showProStore = true
            } else {
                appState.maxExtractionDuration = duration
            }
        } label: {
            HStack {
                Text(extractionDurationLabel(for: duration))
                Spacer()
                if isLocked {
                    Label {
                        Text("\(extractionDurationLabelText(for: duration)) · GIFBloom Pro")
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(LF.actionPrimary)
                }
            }
        }
        .accessibilityLabel(isLocked
            ? Text("\(extractionDurationLabelText(for: duration)), GIFBloom Pro")
            : Text(extractionDurationLabelText(for: duration)))
    }

    private func extractionDurationLabel(for duration: Double) -> LocalizedStringKey {
        switch Int(duration.rounded()) {
        case 3: "3 秒"
        case 5: "5 秒"
        default: "10 秒"
        }
    }

    private func extractionDurationLabelText(for duration: Double) -> String {
        switch Int(duration.rounded()) {
        case 3: NSLocalizedString("3 秒", comment: "Extraction duration")
        case 5: NSLocalizedString("5 秒", comment: "Extraction duration")
        default: NSLocalizedString("10 秒", comment: "Extraction duration")
        }
    }

    private func settingsRow<Control: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.body)
                .foregroundStyle(LF.textPrimary)
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 8)
    }

    private func aboutLink(
        _ title: LocalizedStringKey,
        icon: String,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            HStack(spacing: 10) {
                Label(title, systemImage: icon)
                    .foregroundStyle(LF.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
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
