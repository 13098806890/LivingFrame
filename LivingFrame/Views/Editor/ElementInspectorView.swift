import LivingFrameCore
import SwiftUI

/// 检查器：按选中类型分派（视频元素 / 音频段）
struct ElementInspectorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SectionCard(title: "检查器") {
            if let id = appState.selectedElementID,
               let element = appState.composition?.elements.first(where: { $0.id == id }) {
                elementInspector(element)
            } else if let id = appState.selectedAudioID,
                      let clip = appState.composition?.audioClips.first(where: { $0.id == id }) {
                audioInspector(clip)
            } else {
                Text("点击时间轴或画布上的元素进行编辑")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
            }
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
                        get: { element.transform.rotation * 180 / .pi },
                        set: { value in
                            appState.updateElement(element.id) { $0.transform.rotation = value * .pi / 180 }
                        }
                    ),
                    range: -180...180,
                    text: "\(Int(element.transform.rotation * 180 / .pi))°"
                )
            }
        }
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
                    text: "\(Int(clip.volume * 100))%"
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
                    text: String(format: NSLocalizedString("dur.sec", comment: "Duration"), clip.fadeIn)
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
                    text: String(format: NSLocalizedString("dur.sec", comment: "Duration"), clip.fadeOut)
                )
            }
        }
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
