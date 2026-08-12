import LivingFrameCore
import SwiftUI

/// 检查器：按选中类型分派（视频元素 / 音频段）
struct ElementInspectorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SectionCard(title: "检查器") {
            if let id = appState.primarySelectedID,
               let element = appState.composition?.elements.first(where: { $0.id == id }) {
                elementInspector(element)
            } else if appState.selectedElementIDs.count > 1 {
                multiSelectionSummary
            } else if let id = appState.selectedAudioID,
                      let clip = appState.composition?.audioClips.first(where: { $0.id == id }) {
                audioInspector(clip)
            } else {
                Text("点击画布或时间轴上的元素进行编辑")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }
        }
    }

    /// 多选时：数量 + 批量操作
    private var multiSelectionSummary: some View {
        VStack(spacing: 10) {
            HStack {
                Text("已选中 \(appState.selectedElementIDs.count) 个素材")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(role: .destructive) {
                    let ids = appState.selectedElementIDs
                    for id in ids {
                        appState.deleteElement(id)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            Text("画布上拖动可一起移动，双指缩放/旋转作用于全部选中素材")
                .font(.caption)
                .foregroundStyle(LF.textSecondary)
        }
    }

    // MARK: - 视频元素

    private func elementInspector(_ element: CompositionElement) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(element.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button { appState.moveElementZ(element.id, up: false) } label: {
                    Image(systemName: "square.3.layers.3d.down.right")
                }
                .buttonStyle(.plain)
                Button { appState.moveElementZ(element.id, up: true) } label: {
                    Image(systemName: "square.3.layers.3d.up.right")
                }
                .buttonStyle(.plain)
                Button(role: .destructive) { appState.deleteElement(element.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                slider(
                    label: "缩放",
                    value: Binding(
                        get: { element.transform.scale },
                        set: { value in
                            appState.updateElement(element.id) { $0.transform.scale = value }
                        }
                    ),
                    range: 0.1...3,
                    text: String(format: "%.0f%%", element.transform.scale * 100)
                )
                slider(
                    label: "旋转",
                    value: Binding(
                        // 画布 y 向上：rotation 正值=逆时针；滑块按常规约定正值=顺时针，故取反
                        get: { -Double(element.transform.rotation) * 180 / Double.pi },
                        set: { value in
                            appState.updateElement(element.id) {
                                $0.transform.rotation = -CGFloat(value * Double.pi / 180)
                            }
                        }
                    ),
                    range: -180...180,
                    text: "\(safeDegrees(-element.transform.rotation))°"
                )
            }

            if case .clip(let clipID) = element.kind,
               let clip = appState.clips.first(where: { $0.id == clipID }) {
                stickerStylePicker(clip)
                edgePicker(clip)
            }
        }
    }

    // MARK: - 贴纸风格

    private func stickerStylePicker(_ clip: SegmentedClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("风格")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StickerStyle.allCases) { style in
                        Button {
                            appState.setClipStickerStyle(clip.id, style)
                        } label: {
                            Text(style.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    clip.stickerStyle == style ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(clip.stickerStyle == style ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 边缘效果

    /// 描边可选颜色
    private let edgeColors: [(name: String, hex: String)] = [
        ("白", "FFFFFF"), ("黑", "000000"), ("金", "E8C05C"),
        ("红", "E74C3C"), ("粉", "FF9FF3"), ("蓝", "54A0FF"),
        ("绿", "1DD1A1"), ("紫", "8B7CF6")
    ]

    private func edgePicker(_ clip: SegmentedClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("边缘")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClipEdgeStyle.displayCases) { style in
                        Button {
                            appState.setClipEdgeStyle(clip.id, style)
                        } label: {
                            Text(style.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    clip.edgeStyle == style ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(clip.edgeStyle == style ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // 描边组合：线条样式 → 粗细 → 颜色
            if clip.edgeStyle.isOutline {
                HStack(spacing: 8) {
                    ForEach(EdgeLineStyle.allCases) { lineStyle in
                        Button {
                            appState.setClipEdgeLineStyle(clip.id, lineStyle)
                        } label: {
                            Text(lineStyle.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    clip.edgeLineStyle == lineStyle ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(clip.edgeLineStyle == lineStyle ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(EdgeThickness.allCases) { thickness in
                        Button {
                            appState.setClipEdgeThickness(clip.id, thickness)
                        } label: {
                            Text(thickness.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    clip.edgeThickness == thickness ? LF.gold : LF.surface2,
                                    in: Capsule()
                                )
                                .foregroundStyle(clip.edgeThickness == thickness ? .black : LF.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 10) {
                    ForEach(edgeColors, id: \.hex) { color in
                        Button {
                            appState.setClipEdgeColor(clip.id, color.hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: color.hex))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle().stroke(
                                        clip.edgeColorHex == color.hex ? LF.gold : LF.surface2,
                                        lineWidth: clip.edgeColorHex == color.hex ? 2.5 : 1
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 音频段

    private func audioInspector(_ clip: AudioClip) -> some View {
        VStack(spacing: 10) {
            HStack {
                Label("音轨片段", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(role: .destructive) { appState.deleteAudio(clip.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                slider(
                    label: "音量",
                    value: Binding(
                        get: { Double(clip.volume) },
                        set: { value in
                            appState.updateAudio(clip.id) { $0.volume = Float(value) }
                        }
                    ),
                    range: 0...1,
                    text: "\(safePercent(Double(clip.volume)))%"
                )
                slider(
                    label: "淡入",
                    value: Binding(
                        get: { clip.fadeIn },
                        set: { value in
                            appState.updateAudio(clip.id) { $0.fadeIn = value }
                        }
                    ),
                    range: 0...2,
                    text: String(format: "%.1f s", clip.fadeIn)
                )
                slider(
                    label: "淡出",
                    value: Binding(
                        get: { clip.fadeOut },
                        set: { value in
                            appState.updateAudio(clip.id) { $0.fadeOut = value }
                        }
                    ),
                    range: 0...2,
                    text: String(format: "%.1f s", clip.fadeOut)
                )
            }
        }
    }

    /// 防 NaN 的角度显示
    private func safeDegrees(_ rotation: CGFloat) -> Int {
        let degrees = rotation * 180 / .pi
        return degrees.isFinite ? Int(degrees.rounded()) : 0
    }

    /// 防 NaN 的百分比显示
    private func safePercent(_ value: Double) -> Int {
        let percent = value * 100
        return percent.isFinite ? Int(percent.rounded()) : 0
    }

    private func slider(
        label: String, value: Binding<Double>, range: ClosedRange<Double>, text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
                Spacer()
                Text(text)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LF.textSecondary)
            }
            Slider(value: value, in: range)
                .tint(LF.gold)
        }
        .frame(maxWidth: .infinity)
    }
}
