import LivingFrameCore
import SwiftUI

/// 编辑一轮播放使用的完整源范围；草稿只在点“完成”时提交，取消不影响工程。
private struct ElementSourceRangeEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let element: CompositionElement
    let source: ElementPlaybackSource
    @State private var start: TimeInterval
    @State private var end: TimeInterval

    init(element: CompositionElement, source: ElementPlaybackSource) {
        self.element = element
        self.source = source
        let range = source.range(for: element)
        _start = State(initialValue: range.start)
        _end = State(initialValue: range.end)
    }

    private var minimumSpan: Double { min(0.1 * source.playbackRate, source.duration) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "film.stack")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(LF.selectionText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("编辑播放范围")
                                    .font(.headline)
                                Text(element.name)
                                    .font(.caption)
                                    .foregroundStyle(LF.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(String(format: "%.2f s", source.duration))
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(LF.textSecondary)
                        }

                        SourceRangeFilmstrip(
                            element: element,
                            source: source,
                            start: start,
                            end: end,
                            clip: clip
                        )
                        .frame(height: 104)

                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.caption2.weight(.bold))
                            Text(String(format: "%.2f–%.2f s", start, end))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                            Spacer()
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("每轮 %.2f s", comment: "Playback cycle duration"),
                                (end - start) / source.playbackRate
                            ))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(LF.textSecondary)
                        }
                        .foregroundStyle(LF.selectionText)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 36)
                        .background(
                            LF.selectionFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(LF.brandTint.opacity(0.16), lineWidth: 1)
                    }

                    endpointSliderCard(
                        title: "入点",
                        subtitle: "播放从这个位置开始",
                        icon: "arrow.right.to.line",
                        value: Binding(
                            get: { start },
                            set: { start = min($0, max(end - minimumSpan, 0)) }
                        ),
                        accessibilityLabel: "源片段起始位置"
                    )

                    endpointSliderCard(
                        title: "出点",
                        subtitle: "播放在这个位置结束",
                        icon: "arrow.left.to.line",
                        value: Binding(
                            get: { end },
                            set: { end = max($0, min(start + minimumSpan, source.duration)) }
                        ),
                        accessibilityLabel: "源片段结束位置"
                    )

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text("两侧变暗区域不会播放。调整后的范围会应用到每一次重复，时间轴上的开始位置保持不变。")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(LF.textSecondary)
                    .padding(.horizontal, 4)

                    Button {
                        start = 0
                        end = source.duration
                    } label: {
                        Label("恢复完整素材", systemImage: "arrow.counterclockwise")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .lfActionButtonStyle(.secondary)
                }
                .padding(16)
            }
            .magicBackground()
            .tint(LF.actionPrimary)
            .lfNavigationTitle("编辑播放片段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        appState.setElementSourceRange(element.id, start: start, end: end)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func endpointSliderCard(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        icon: String,
        value: Binding<Double>,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.selectionText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer()
                Text(String(format: "%.2f s", value.wrappedValue))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(LF.selectionText)
            }
            Slider(value: value, in: 0...source.duration)
                .accessibilityLabel(Text(accessibilityLabel))
            HStack {
                Text("0.00 s")
                Spacer()
                Text(String(format: "%.2f s", source.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(LF.textSecondary)
        }
        .padding(14)
        .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(LF.brandTint.opacity(0.12), lineWidth: 1)
        }
    }

    private var clip: SegmentedClip? {
        guard case .clip(let id) = element.kind else { return nil }
        return FrameCache.shared.clip(id: id) ?? appState.clips.first(where: { $0.id == id })
    }

    private func endpointLabel(_ title: LocalizedStringKey, time: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(format: "%.2f s", time)).monospacedDigit()
        }
        .font(.subheadline)
    }
}

/// 播放范围的低分辨率预览，和背景、拼接素材共用同一套源范围设置。
private struct SourceRangeFilmstrip: View {
    let element: CompositionElement
    let source: ElementPlaybackSource
    let start: Double
    let end: Double
    let clip: SegmentedClip?
    @State private var frames: [CGImage?] = []

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let left = width * start / source.duration
            let right = width * end / source.duration
            HStack(spacing: 0) {
                ForEach(frames.indices, id: \.self) { index in
                    Group {
                        if let frame = frames[index] {
                            Image(decorative: frame, scale: 1).resizable().scaledToFill()
                        } else {
                            LF.surface2
                        }
                    }
                    .frame(width: width / CGFloat(max(frames.count, 1)), height: geometry.size.height)
                    .clipped()
                }
            }
            .frame(width: width, height: geometry.size.height)
            .overlay(alignment: .leading) {
                TimelineInactiveRangeMask(
                    totalWidth: width,
                    leftWidth: left,
                    rightWidth: width - right,
                    height: geometry.size.height
                )
                .frame(width: width, height: geometry.size.height)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(LF.selectionFill.opacity(0.18))
                    .frame(width: max(right - left, 1))
                    .offset(x: left)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Capsule()
                        .fill(LF.selectionStroke)
                        .frame(width: 4, height: geometry.size.height)
                    Spacer()
                    Capsule()
                        .fill(LF.selectionStroke)
                        .frame(width: 4, height: geometry.size.height)
                }
                .frame(width: max(right - left, 1))
                .offset(x: left)
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .task(id: element.id) {
            let kind = element.kind
            let duration = source.duration
            let clip = clip
            let worker = Task.detached(priority: .utility) {
                var result: [CGImage?] = []
                for index in 0..<12 {
                    guard !Task.isCancelled else { return result }
                    let time = duration * (Double(index) + 0.5) / 12
                    result.append(autoreleasepool {
                        Self.thumbnail(kind: kind, clip: clip, time: time)
                    })
                }
                return result
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            frames = result
        }
    }

    nonisolated private static func thumbnail(
        kind: ElementKind,
        clip: SegmentedClip?,
        time: TimeInterval
    ) -> CGImage? {
        switch kind {
        case .clip:
            guard let clip, clip.fps.isFinite, !clip.playbackFrameIndices.isEmpty else { return nil }
            let indices = clip.playbackFrameIndices
            let offset = min(max(Int(time * max(clip.fps, 0.001)), 0), indices.count - 1)
            return FrameCache.shared.cachedThumbnail(
                for: clip,
                index: indices[offset],
                maxPixelSize: 160
            )
        case .background(let id):
            guard let image = BackgroundStore.shared.loadFrame(named: id, at: time) else { return nil }
            return resizedThumbnail(image)
        case .decoration(let id), .effect(let id):
            return DecorationRenderer.previewThumbnail(for: id, at: time)
        case .text, .canvasEdge, .collage:
            return nil
        }
    }

    nonisolated private static func resizedThumbnail(_ image: CGImage) -> CGImage? {
        let scale = min(160 / Double(max(image.width, image.height)), 1)
        let width = max(Int(Double(image.width) * scale), 1)
        let height = max(Int(Double(image.height) * scale), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }
}

/// 素材播放参数：起始帧/结束帧定义循环单元，播放次数定义时间轴内重复次数。
/// 背景检查器和拼接编辑器都通过这个组件修改，确保规则和文案一致。
struct ElementPlaybackControls: View {
    @EnvironmentObject private var appState: AppState
    let element: CompositionElement
    let source: ElementPlaybackSource
    @State private var isEditingSourceRange = false

    private var count: Int {
        element.resolvedPlaybackCount(cycleDuration: source.cycleDuration(for: element))
    }

    private var range: SourcePlaybackRange {
        source.range(for: element)
    }

    private var cycleDuration: TimeInterval {
        max(range.span / source.playbackRate, 0.001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "film.stack")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LF.selectionText)
                    .frame(width: 28, height: 28)
                    .background(LF.selectionFill.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("播放范围")
                        .font(.subheadline.weight(.semibold))
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("%.2f–%.2f s · 每轮 %.2f s", comment: "Selected playback range and cycle duration"),
                        range.start, range.end, cycleDuration
                    ))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer(minLength: 8)
            }

            Button {
                appState.pause()
                isEditingSourceRange = true
            } label: {
                HStack(spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("调整起始帧和结束帧")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LF.textPrimary)
                        Text("选择每轮播放的素材范围")
                            .font(.caption2)
                            .foregroundStyle(LF.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LF.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 56)
                .background(LF.surface2.opacity(0.66), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(LF.brandTint.opacity(0.14), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Label("循环次数", systemImage: "repeat")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LF.textSecondary)
                Spacer()
                Menu {
                    ForEach([1, 2, 3], id: \.self) { value in
                        Button(value == 1 ? NSLocalizedString("仅播放一次", comment: "Play once") : String.localizedStringWithFormat(
                            NSLocalizedString("播放 %1$lld 次", comment: "Playback repeat count"),
                            Int64(value)
                        )) {
                            appState.setElementPlaybackCount(element.id, count: value)
                        }
                    }
                    Button("自定义次数") {
                        appState.setElementPlaybackCount(element.id, count: max(count, 4))
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(count == 1 ? NSLocalizedString("仅播放一次", comment: "Play once") : String.localizedStringWithFormat(
                            NSLocalizedString("播放 %1$lld 次", comment: "Playback repeat count"),
                            Int64(count)
                        ))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(LF.textPrimary)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .background(LF.surface2.opacity(0.7), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(LF.brandTint.opacity(0.14), lineWidth: 1)
                    }
                }
            }
            if count > 3 {
                Stepper(String.localizedStringWithFormat(
                    NSLocalizedString("总共播放 %1$lld 次", comment: "Total playback repetition count"), Int64(count)
                ), value: Binding(
                    get: { min(count, 99) },
                    set: { appState.setElementPlaybackCount(element.id, count: $0) }
                ), in: 1...99)
                .font(.caption)
            }
            Text("时间轴左右手柄用于调整这段素材在工程中的播放长度。")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
        }
        .padding(12)
        .background(LF.surface2.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LF.brandTint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityIdentifier("element-playback-controls")
        .sheet(isPresented: $isEditingSourceRange) {
            ElementSourceRangeEditor(element: element, source: source)
                .environmentObject(appState)
        }
    }
}
