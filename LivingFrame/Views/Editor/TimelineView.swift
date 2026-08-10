import LivingFrameCore
import SwiftUI

/// 双轨时间轴：视频元素轨 + 音频轨，拖动调节起止位置
struct TimelineView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("时间轴")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)
                Spacer()
                Text(String(format: NSLocalizedString("dur.sec", comment: "Duration"), appState.composition?.duration ?? 0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LF.textSecondary)
            }

            if let comp = appState.composition {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // 视频元素轨
                        trackBackground
                        ForEach(comp.elements) { element in
                            elementBar(element, width: geo.size.width)
                        }
                        // 音频轨
                        ForEach(comp.audioClips) { clip in
                            audioBar(clip, width: geo.size.width)
                        }
                        playhead(width: geo.size.width)
                    }
                }
                .frame(height: 96)
            }
        }
    }

    private var trackBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LF.surface2.opacity(0.5))
            .frame(height: 96)
    }

    private func xScale(_ width: CGFloat) -> CGFloat {
        max(width / max(appState.composition?.duration ?? 1, 0.1), 0)
    }

    // MARK: - 视频元素

    private func elementBar(_ element: CompositionElement, width: CGFloat) -> some View {
        let scale = xScale(width)
        let startX = element.startTime * scale
        let barWidth = max((element.endTime - element.startTime) * scale, 20)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color(for: element))
                .frame(width: barWidth, height: 34)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            appState.selectedElementID == element.id ? LF.gold : .clear,
                            lineWidth: 2
                        )
                }
            if appState.selectedElementID == element.id {
                Label(element.name, systemImage: elementSymbol(element))
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
        }
        .position(x: startX + barWidth / 2, y: 22)
        .gesture(dragElement(element, scale: scale))
        .onTapGesture {
            appState.selectedElementID = element.id
            appState.selectedAudioID = nil
        }
    }

    private func elementSymbol(_ element: CompositionElement) -> String {
        switch element.kind {
        case .clip: "person.crop.rectangle"
        case .decoration: "rectangle.badge.plus"
        case .effect: "sparkles"
        }
    }

    private func color(for element: CompositionElement) -> Color {
        switch element.kind {
        case .clip: LF.magic.opacity(0.75)
        case .decoration: LF.gold.opacity(0.75)
        case .effect: Color.pink.opacity(0.75)
        }
    }

    private func dragElement(_ element: CompositionElement, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition else { return }
                let delta = value.translation.width / scale
                let duration = element.endTime - element.startTime
                let newStart = min(max(element.startTime + delta, 0), comp.duration - duration)
                appState.updateElement(element.id) { element in
                    element.startTime = newStart
                    element.endTime = newStart + duration
                }
            }
    }

    // MARK: - 音频

    private func audioBar(_ clip: AudioClip, width: CGFloat) -> some View {
        let scale = xScale(width)
        let startX = clip.startTime * scale
        let barWidth = max(clip.duration * scale, 20)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.teal.opacity(0.8))
                .frame(width: barWidth, height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            appState.selectedAudioID == clip.id ? LF.gold : .clear,
                            lineWidth: 2
                        )
                }
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                Text(String(format: "%.1f", clip.volume))
            }
            .font(.caption2)
            .padding(.horizontal, 6)
        }
        .position(x: startX + barWidth / 2, y: 74)
        .gesture(dragAudio(clip, scale: scale))
        .onTapGesture {
            appState.selectedAudioID = clip.id
            appState.selectedElementID = nil
        }
    }

    private func dragAudio(_ clip: AudioClip, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition else { return }
                let delta = value.translation.width / scale
                let newStart = min(max(clip.startTime + delta, 0), comp.duration - clip.duration)
                appState.updateAudio(clip.id) { clip in
                    clip.startTime = newStart
                }
            }
    }

    // MARK: - 播放头

    private func playhead(width: CGFloat) -> some View {
        let x = appState.currentTime * xScale(width)
        return Rectangle()
            .fill(LF.gold)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .position(x: x, y: 48)
    }
}
