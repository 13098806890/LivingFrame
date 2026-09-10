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
                VStack(alignment: .leading, spacing: 20) {
                    Text(element.name).font(.headline)
                    SourceRangeFilmstrip(
                        element: element,
                        source: source,
                        start: start,
                        end: end,
                        clip: clip
                    )
                    .frame(height: 76)
                    endpointLabel("起始位置", time: start)
                    Slider(value: Binding(
                        get: { start },
                        set: { start = min($0, max(end - minimumSpan, 0)) }
                    ), in: 0...source.duration)
                    .accessibilityLabel("源片段起始位置")
                    endpointLabel("结束位置", time: end)
                    Slider(value: Binding(
                        get: { end },
                        set: { end = max($0, min(start + minimumSpan, source.duration)) }
                    ), in: 0...source.duration)
                    .accessibilityLabel("源片段结束位置")
                    Text(String(format: "每次播放 %.2f 秒", (end - start) / source.playbackRate))
                        .font(.subheadline.monospacedDigit())
                    Text("暗区不会播放。修改片段会应用到每一次重复，时间轴上的开始位置保持不变。")
                        .font(.caption)
                        .foregroundStyle(LF.textSecondary)
                    Button("恢复完整素材") {
                        start = 0
                        end = source.duration
                    }
                }
                .padding(20)
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

    private var clip: SegmentedClip? {
        guard case .clip(let id) = element.kind else { return nil }
        return FrameCache.shared.clip(id: id) ?? appState.clips.first(where: { $0.id == id })
    }

    private func endpointLabel(_ title: String, time: Double) -> some View {
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
                    .strokeBorder(LF.selectionStroke, lineWidth: 3)
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
        case .text, .canvasEdge:
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("重复播放", systemImage: "repeat")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    ForEach([1, 2, 3], id: \.self) { value in
                        Button(value == 1 ? "仅播放一次" : "播放 \(value) 次") {
                            appState.setElementPlaybackCount(element.id, count: value)
                        }
                    }
                    Button("自定义次数") {
                        appState.setElementPlaybackCount(element.id, count: max(count, 4))
                    }
                } label: {
                    Text(count == 1 ? "仅播放一次" : "播放 \(count) 次")
                        .foregroundStyle(LF.selectionText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(LF.selectionFill, in: Capsule())
                }
            }
            if count > 3 {
                Stepper("总共播放 \(count) 次", value: Binding(
                    get: { min(count, 99) },
                    set: { appState.setElementPlaybackCount(element.id, count: $0) }
                ), in: 1...99)
                .font(.caption)
            }
            HStack(spacing: 8) {
                Label("源片段", systemImage: "film")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LF.textSecondary)
                Spacer(minLength: 8)
                Text(String(format: "%.2f–%.2f / %.2f s", range.start, range.end, source.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LF.textPrimary)
            }
            Button {
                appState.pause()
                isEditingSourceRange = true
            } label: {
                Label("编辑起始帧和结束帧", systemImage: "scissors")
                    .font(.subheadline)
                    .foregroundStyle(LF.actionPrimary)
            }
            Text(count > 1
                ? "每次重复当前选中的源片段；修改后保持时间轴起点不变。"
                : "动态素材可调整源片段的起始帧和结束帧；时间轴左右手柄用于单次播放。")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
        }
        .padding(10)
        .background(LF.surface2, in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $isEditingSourceRange) {
            ElementSourceRangeEditor(element: element, source: source)
                .environmentObject(appState)
        }
    }
}
