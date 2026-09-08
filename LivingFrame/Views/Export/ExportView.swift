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
    @State private var exportedChatSticker = false
    @State private var exportedURL: URL?
    @State private var exportError: String?
    @State private var savedToLibrary = false
    @State private var exportTask: Task<Void, Never>?
    /// 打开导出页时冻结预览时刻，避免编辑器仍在播放时反复触发高成本渲染。
    @State private var previewTime: TimeInterval = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let comp = appState.composition {
                        summaryCard(comp)
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
                            Text("10 fps").tag(10.0)
                            Text("15 fps").tag(15.0)
                            Text("30 fps（流畅）").tag(30.0)
                        }
                        .pickerStyle(.segmented)
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

                    if appState.isExporting {
                    SectionCard(title: "导出中") {
                        ProgressView(value: appState.exportProgress)
                            .tint(LF.gold)
                        Text(String(format: "%d%%", Int(appState.exportProgress * 100)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(LF.textSecondary)
                    }
                    }

                    if let exportedURL {
                    SectionCard(title: "完成") {
                        VStack(alignment: .leading, spacing: 8) {
                            if exportedChatSticker {
                                Text("将 GIF 存到相册后，可在微信中发送或尝试添加到自定义表情；无需转成视频。")
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
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(exportedURL.lastPathComponent)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Label("导出成功", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(LF.gold)
                                    if let exportedFileSize {
                                        Label(exportedFileSize, systemImage: "internaldrive")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(LF.textSecondary)
                                    }
                                }
                                Spacer()
                                ShareLink(item: exportedURL) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(MagicButtonStyle())
                            }
                        }
                        Button {
                            saveToLibrary(url: exportedURL)
                        } label: {
                            Label(
                                savedToLibrary ? "已存入相册" : "存到相册",
                                systemImage: savedToLibrary ? "checkmark" : "photo.badge.plus"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(MagicButtonStyle(prominent: false))
                        .disabled(savedToLibrary)
                    }
                    }

                    if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
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
                    Button(appState.isExporting ? "停止导出" : "取消") {
                        if appState.isExporting {
                            exportTask?.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出") {
                        export()
                    }
                    .tint(LF.actionPrimary)
                    .disabled(appState.isExporting)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            format = appState.defaultFormat
            fps = appState.exportFPS
            previewTime = appState.currentTime
        }
        .onDisappear {
            exportTask?.cancel()
        }
    }

    /// 两列胶囊比四等分 segmented picker 更适合较长的中文格式名称，
    /// 也能保持每个选项的完整可读性。
    private var exportFormatPicker: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            ForEach(ExportFormat.allCases) { option in
                Button {
                    format = option
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
                            .stroke(
                                format == option ? LF.selectionStroke : LF.brandTint.opacity(0.2),
                                lineWidth: format == option ? 1.8 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func summaryCard(_ comp: Composition) -> some View {
        SectionCard(title: "工程信息") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(comp.name)
                        .font(.headline)
                    Text(String(
                        format: NSLocalizedString("canvas.meta", comment: "Canvas metadata"),
                        Int(comp.canvas.width), Int(comp.canvas.height), Int(comp.duration),
                        comp.elements.count, comp.audioClips.count
                    ))
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer()
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(LF.gold)
            }
        }
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

    private var exportedFileSize: String? {
        guard let exportedURL,
              let bytes = try? exportedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func saveToLibrary(url: URL) {
        Task { @MainActor in
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

                HStack {
                    Label("\(Int(outputSize.width)) × \(Int(outputSize.height)) px", systemImage: "rectangle.dashed")
                    Spacer()
                    Text("\(Int(fps)) fps · 约 \(frameCount) 帧")
                }
                .font(.caption.monospacedDigit())
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
