import LivingFrameCore
import Photos
import SwiftUI

/// 导出：格式/帧率 → 进度 → 分享/存相册
struct ExportView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .gif
    @State private var fps: Double = 15
    @State private var exportedURL: URL?
    @State private var exportError: String?
    @State private var savedToLibrary = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let comp = appState.composition {
                    summaryCard(comp)
                }

                SectionCard(title: "导出格式") {
                    Picker("格式", selection: $format) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(format.subtitle)
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)

                    if format != .livePhoto {
                        Picker("帧率", selection: $fps) {
                            Text("15 fps（文件小）").tag(15.0)
                            Text("30 fps（流畅）").tag(30.0)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if appState.isExporting {
                    SectionCard(title: "导出中") {
                        ProgressView(value: appState.exportProgress)
                            .tint(LF.gold)
                        Text(String(format: NSLocalizedString("percent", comment: "Progress"), Int(appState.exportProgress * 100)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(LF.textSecondary)
                    }
                }

                if let exportedURL {
                    SectionCard(title: "完成") {
                        VStack(alignment: .leading, spacing: 8) {
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

                Spacer()
            }
            .padding()
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        export()
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(MagicButtonStyle())
                    .disabled(appState.isExporting)
                }
            }
        }
        .presentationDetents([.large])
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
        savedToLibrary = false
        exportError = nil
        Task {
            do {
                let url = try await appState.export(format: format, fps: fps)
                exportedURL = url
                if format == .livePhoto {
                    savedToLibrary = true
                }
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func saveToLibrary(url: URL) {
        if url.pathExtension.lowercased() == "gif" {
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    savedToLibrary = success
                }
            }
        } else {
            UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
            savedToLibrary = true
        }
    }
}
