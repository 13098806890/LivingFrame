import LivingFrameCore
import Photos
import SwiftUI
import UIKit

/// 导出：格式/帧率 → 进度 → 分享/存相册
struct ExportView: View {
    private enum WeChatGIFPreset: String, CaseIterable, Identifiable {
        case sticker
        case highResolution

        var id: String { rawValue }
        var pixelSize: CGFloat { self == .sticker ? 240 : 720 }
        var title: String { self == .sticker ? "表情 240" : "高清 720" }
        var detail: String {
            switch self {
            case .sticker:
                return "240×240、15 fps。适合尝试添加到微信自定义表情。"
            case .highResolution:
                return "720×720、15 fps。保留更多细节，适合以 GIF 图片发送或在微信中实测；不保证可添加到自定义表情面板。"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .gif
    @State private var fps: Double = 15
    @State private var resolution: ExportResolution = .original
    @State private var chatSticker = false
    @State private var weChatGIFPreset: WeChatGIFPreset = .sticker
    @State private var showAdvancedFormats = false
    @State private var exportedChatSticker = false
    @State private var exportedURL: URL?
    @State private var exportError: String?
    @State private var savedToLibrary = false
    @State private var isSavingToLibrary = false
    @State private var exportTask: Task<Void, Never>?
    /// 打开导出页时冻结预览时刻，避免编辑器仍在播放时反复触发高成本渲染。
    @State private var previewTime: TimeInterval = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if appState.isExporting || isSavingToLibrary {
                        exportProgressBanner
                    } else if let exportedURL {
                        exportResultBanner(url: exportedURL)
                    } else if let exportError {
                        exportErrorBanner(message: exportError)
                    }

                    if let comp = appState.composition {
                        exportContext(comp)
                    }

                    SectionCard(title: "导出格式") {
                        exportFormatPicker

                        Text(format.subtitle)
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)

                        if format == .gif {
                        Toggle("微信 GIF 优化", isOn: $chatSticker)
                            .tint(LF.actionPrimary)
                        if chatSticker {
                            Picker("GIF 预设", selection: $weChatGIFPreset) {
                                ForEach(WeChatGIFPreset.allCases) { preset in
                                    Text(preset.title).tag(preset)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text(weChatGIFPreset.detail + " 超过 10 MB 时会均匀抽帧，最低 6 fps；不会缩小画面。建议使用 1:1 画布让主体显示更大。半透明阴影会转为硬边。")
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                        }
                        }

                        if format != .livePhoto && !(format == .gif && chatSticker) {
                        Picker("分辨率", selection: $resolution) {
                            ForEach(ExportResolution.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        Picker("帧率", selection: $fps) {
                            ForEach(availableFPSOptions, id: \.self) { option in
                                Text("\(fpsTitle(option)) fps").tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("当前工程动态素材最高：\(fpsTitle(appState.maximumSourceFPS)) fps")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                        } else if format == .livePhoto {
                        Label("Live Photo 使用原始画布与工程帧率", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                        }
                    }
                    .disabled(appState.isExporting)

                    if let composition = appState.composition {
                        ExportFramePreview(
                            composition: composition,
                            time: previewTime,
                            outputSize: previewOutputSize(for: composition),
                            maximumRenderSize: previewMaximumRenderSize,
                            fps: previewFPS(for: composition)
                        )
                    }

                    Text("文件体积会随画面细节、透明区域和编码器变化；导出完成后会显示准确结果。")
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
                .padding()
            }
            .scrollIndicators(.hidden)
            .lfNavigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(appState.isExporting || isSavingToLibrary ? "处理中…" : "取消") {
                        if appState.isExporting {
                            exportTask?.cancel()
                        } else if !isSavingToLibrary {
                            dismiss()
                        }
                    }
                    .disabled(isSavingToLibrary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出") {
                        export()
                    }
                    .tint(LF.actionPrimary)
                    .disabled(appState.isExporting || isSavingToLibrary)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            format = appState.defaultFormat
            showAdvancedFormats = appState.defaultFormat != .gif
            fps = normalizedFPSSelection(appState.exportFPS)
            previewTime = appState.currentTime
        }
        .onDisappear {
            exportTask?.cancel()
        }
    }

    private var exportProgressBanner: some View {
        SectionCard(title: isSavingToLibrary && !appState.isExporting ? "保存到相册" : "导出中") {
            HStack(spacing: 10) {
                if appState.isExporting {
                    ProgressView(value: appState.exportProgress)
                        .tint(LF.gold)
                    Text(String(format: "%d%%", Int(appState.exportProgress * 100)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                } else {
                    ProgressView()
                        .tint(LF.gold)
                    Text("正在写入系统相册…")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
            }
        }
    }

    private func exportResultBanner(url: URL) -> some View {
        SectionCard(title: "导出完成") {
            VStack(alignment: .leading, spacing: 8) {
                if exportedChatSticker {
                    Text("GIF 可直接分享到微信，也可以尝试添加到自定义表情。")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
                if let notice = appState.exportNotice {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
                if format == .livePhoto {
                    Text("已存入系统相册，打开「照片」长按即可看到动态效果")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("导出成功", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LF.gold)
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                            .lineLimit(1)
                        if let exportedFileSize {
                            Label(exportedFileSize, systemImage: "internaldrive")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(LF.textSecondary)
                        }
                    }

                    Spacer()

                    ShareLink(item: url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(MagicButtonStyle())
                }

                Button {
                    saveToLibrary(url: url)
                } label: {
                    Label(
                        savedToLibrary ? "已存入相册" : "存到相册",
                        systemImage: savedToLibrary ? "checkmark" : "photo.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MagicButtonStyle(prominent: false))
                .disabled(savedToLibrary || isSavingToLibrary)
            }
        }
    }

    private func exportErrorBanner(message: String) -> some View {
        SectionCard(title: "导出失败") {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 普通路径只突出 GIF；低频的视频和 Live Photo 格式放进高级选项。
    private var exportFormatPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            formatButton(.gif)

            DisclosureGroup(isExpanded: $showAdvancedFormats) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(ExportFormat.allCases.filter { $0 != .gif }) { option in
                        formatButton(option)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack {
                    Label("更多导出格式", systemImage: "slider.horizontal.3")
                    Spacer()
                    if format != .gif {
                        Text(format.title)
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                            .lineLimit(1)
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LF.header)
            }
            .tint(LF.header)
        }
        .accessibilityElement(children: .contain)
    }

    private func formatButton(_ option: ExportFormat) -> some View {
        Button {
            format = option
            if option != .gif {
                showAdvancedFormats = true
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: format == option ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                Text(option.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(format == option ? LF.selectionText : LF.textPrimary)
            .padding(.horizontal, 11)
            .frame(minHeight: 46, alignment: .leading)
            .background(
                format == option ? LF.selectionFill : LF.surface2,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        format == option ? LF.selectionStroke : LF.brandTint.opacity(0.2),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func exportContext(_ comp: Composition) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "film")
                .foregroundStyle(LF.gold)
            VStack(alignment: .leading, spacing: 3) {
                Text(comp.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("时长 \(String(format: "%.1f", max(comp.duration, 0))) 秒 · 导出预览")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func export() {
        exportedURL = nil
        exportedChatSticker = false
        savedToLibrary = false
        exportError = nil
        let selectedFormat = format
        let selectedFPS = fps
        let selectedResolution = resolution
        let isChatSticker = format == .gif && chatSticker
        let chatGIFPixelSize = weChatGIFPreset.pixelSize
        exportTask = Task { @MainActor in
            do {
                let url = try await appState.export(
                    format: selectedFormat,
                    fps: selectedFPS,
                    chatSticker: isChatSticker,
                    chatGIFPixelSize: chatGIFPixelSize,
                    resolution: selectedResolution
                )
                exportedURL = url
                exportedChatSticker = isChatSticker
                if selectedFormat == .livePhoto {
                    savedToLibrary = true
                }
            } catch is CancellationError {
                // 用户主动停止，不显示错误。
            } catch ExportError.cancelled {
                // 用户主动停止，不显示错误。
            } catch {
                let nsError = error as NSError
                let logPrefix = selectedFormat == .livePhoto ? "xdz.livephoto" : "export"
                LogStore.log(
                    "\(logPrefix) failed format=\(selectedFormat.rawValue) domain=\(nsError.domain) "
                        + "code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)"
                )
                exportError = error.localizedDescription
            }
        }
    }

    private var previewMaximumRenderSize: CGFloat? {
        if format == .gif && chatSticker { return weChatGIFPreset.pixelSize }
        if format == .livePhoto { return nil }
        return resolution.maxPixelSize
    }

    private func previewOutputSize(for composition: Composition) -> CGSize {
        if format == .gif && chatSticker {
            let size = weChatGIFPreset.pixelSize
            return CGSize(width: size, height: size)
        }
        if format == .livePhoto { return composition.renderRect.size }
        return resolution.outputSize(
            for: composition.renderRect.size,
            requiresEvenDimensions: format == .hevcAlpha || format == .h264
        )
    }

    private func previewFPS(for composition: Composition) -> Double {
        if format == .livePhoto { return composition.fps }
        if format == .gif && chatSticker { return 15 }
        return fps
    }

    private var availableFPSOptions: [Double] {
        appState.availableExportFPSOptions
    }

    private func normalizedFPSSelection(_ preferred: Double) -> Double {
        let options = availableFPSOptions
        guard !options.isEmpty else { return preferred }
        if let exact = options.first(where: { abs($0 - preferred) < 0.01 }) {
            return exact
        }
        return options.last ?? preferred
    }

    private func fpsTitle(_ fps: Double) -> String {
        if abs(fps.rounded() - fps) < 0.01 { return String(Int(fps.rounded())) }
        return String(format: "%.1f", fps)
    }

    private var exportedFileSize: String? {
        guard let exportedURL,
              let bytes = try? exportedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func saveToLibrary(url: URL) {
        guard !isSavingToLibrary else { return }
        isSavingToLibrary = true
        Task { @MainActor in
            defer { isSavingToLibrary = false }
            do {
                let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                let authorized: Bool
                if currentStatus == .notDetermined {
                    authorized = await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
                } else {
                    authorized = currentStatus == .authorized || currentStatus == .limited
                }
                guard authorized else { throw AppStateError.photoLibraryDenied }
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    if url.pathExtension.lowercased() == "gif" {
                        request.addResource(with: .photo, fileURL: url, options: nil)
                    } else {
                        request.addResource(with: .video, fileURL: url, options: nil)
                    }
                }
                savedToLibrary = true
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

/// 导出前只渲染当前一帧；不会创建 GIF、分配视频编码器或读取完整帧序列。
private struct ExportFramePreview: View {
    let composition: Composition
    let time: TimeInterval
    let outputSize: CGSize
    let maximumRenderSize: CGFloat?
    let fps: Double

    @State private var image: UIImage?
    @State private var isRendering = true

    private var renderKey: String {
        "\(composition.id.uuidString)-\(Int(time * 100))-\(Int(outputSize.width))x\(Int(outputSize.height))-\(Int(maximumRenderSize ?? 0))"
    }

    private var frameCount: Int {
        max(Int((composition.duration * fps).rounded(.up)), 1)
    }

    var body: some View {
        SectionCard(title: "导出预览") {
            VStack(spacing: 10) {
                ZStack {
                    CheckerboardView()
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    } else if isRendering {
                        ProgressView()
                            .tint(LF.actionPrimary)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(LF.textSecondary)
                    }
                }
                .aspectRatio(outputSize.width / max(outputSize.height, 1), contentMode: .fit)
                .frame(maxHeight: 190)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(LF.brandTint.opacity(0.2), lineWidth: 1)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("最终输出尺寸")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                        Text("\(Int(outputSize.width)) × \(Int(outputSize.height)) px")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(LF.textPrimary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("帧率 / 总帧数")
                            .font(.caption)
                            .foregroundStyle(LF.textSecondary)
                        Text("\(Int(fps)) fps · \(frameCount) 帧")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(LF.textPrimary)
                    }
                }
                Text("画面按比例预览，实际像素尺寸以这里显示的最终输出为准。")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }
        }
        .task(id: renderKey) {
            isRendering = true
            image = nil
            let snapshot = composition
            let frameTime = time
            let maxPixel = maximumRenderSize
            let rendered = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    CompositionRenderer(frameMaxPixelSize: maxPixel).render(snapshot, at: frameTime)
                }
            }.value
            guard !Task.isCancelled else { return }
            image = rendered.map(UIImage.init(cgImage:))
            isRendering = false
        }
    }
}
