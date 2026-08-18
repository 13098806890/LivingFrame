import LivingFrameCore
import SwiftUI

/// 时间轴（参考剪映/CapCut 逻辑）：
/// - 每个素材一行（画中画式多轨，上下分开）
/// - 素材条内显示帧缩略图拼贴
/// - 顶部刻度尺 + 当前时间，播放头可拖动定位
/// - 双指捏合缩放时间刻度（1x~8x）
/// - 拖动整体移动（就近磁吸对齐），左右边缘手柄裁剪开始/消失时间
struct TimelineView: View {
    @EnvironmentObject private var appState: AppState

    private let rowHeight: CGFloat = 30
    private let rowSpacing: CGFloat = 3
    private let rulerHeight: CGFloat = 18
    /// 时间轴缩放（1x = 全时长铺满，8x = 放大到帧级）
    @State private var zoom: CGFloat = 1
    @State private var lastPinchZoom: CGFloat = 1

    private var rows: Int {
        guard let comp = appState.composition else { return 0 }
        return comp.elements.count + comp.audioClips.count
    }

    private var totalHeight: CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * rowSpacing
    }

    /// 每像素对应的秒数（缩放后）
    private func secondsPerPoint(_ width: CGFloat) -> CGFloat {
        let duration = max(appState.composition?.duration ?? 1, 0.1)
        return (duration / width) / zoom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("时间轴")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)
                Spacer()
                Text(String(format: "%.2f / %.1f s", appState.currentTime, appState.composition?.duration ?? 0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LF.textSecondary)
            }

            if let comp = appState.composition, !comp.elements.isEmpty || !comp.audioClips.isEmpty {
                GeometryReader { geo in
                    let width = geo.size.width
                    let spp = secondsPerPoint(width)
                    ZStack(alignment: .topLeading) {
                        // 刻度尺
                        ruler(width: width)
                            .frame(height: rulerHeight)
                        // 轨道背景（多行）
                        ForEach(0..<rows, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LF.surface2.opacity(0.4))
                                .frame(width: width, height: rowHeight)
                                .position(x: width / 2, y: rulerHeight + rowCenterY(i))
                        }
                        // 元素行
                        ForEach(Array(comp.elements.enumerated()), id: \.element.id) { i, element in
                            elementRow(element, spp: spp)
                                .position(x: rowX(element, spp: spp), y: rulerHeight + rowCenterY(i))
                        }
                        // 音频行（每条音轨一行，元素行之下依次排开）
                        ForEach(Array(comp.audioClips.enumerated()), id: \.element.id) { i, audio in
                            audioRow(audio, spp: spp)
                                .position(x: audioX(audio, spp: spp), y: rulerHeight + rowCenterY(comp.elements.count + i))
                        }
                        // 播放头（可拖动定位）
                        playhead(spp: spp, height: totalHeight)
                    }
                    .contentShape(Rectangle())
                    .gesture(pinchZoomGesture)
                }
                .frame(height: rulerHeight + totalHeight)
            } else {
                Text("添加素材后显示时间轴")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 40)
            }
        }
    }

    // MARK: - 缩放（双指捏合）

    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(max(lastPinchZoom * value.magnification, 1), 8)
            }
            .onEnded { _ in
                lastPinchZoom = zoom
            }
    }

    // MARK: - 刻度尺

    private func ruler(width: CGFloat) -> some View {
        let duration = max(appState.composition?.duration ?? 1, 0.1)
        let spp = secondsPerPoint(width)
        // 刻度间隔：保证标签间距 ≥ 48pt
        let candidates: [CGFloat] = [0.5, 1, 2, 5, 10, 15, 30]
        let step = candidates.first { $0 / spp >= 48 } ?? 60
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(LF.surface2.opacity(0.5))
            HStack(spacing: 0) {
                ForEach(0..<Int(duration / step) + 1, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle()
                            .fill(LF.textSecondary.opacity(0.6))
                            .frame(width: 1, height: 6)
                        Text("\(Int(CGFloat(i) * step))s")
                            .font(.system(size: 8))
                            .foregroundStyle(LF.textSecondary)
                    }
                    .frame(width: step / spp, alignment: .leading)
                }
            }
        }
        .clipped()
    }

    // MARK: - 行定位

    private func rowCenterY(_ i: Int) -> CGFloat {
        CGFloat(i) * (rowHeight + rowSpacing) + rowHeight / 2
    }

    private func rowX(_ element: CompositionElement, spp: CGFloat) -> CGFloat {
        let barWidth = max((element.endTime - element.startTime) / spp, 20)
        return element.startTime / spp + barWidth / 2
    }

    private func audioX(_ clip: AudioClip, spp: CGFloat) -> CGFloat {
        let barWidth = max(clip.duration / spp, 20)
        return clip.startTime / spp + barWidth / 2
    }

    // MARK: - 元素行（帧缩略图拼贴）

    private func elementRow(_ element: CompositionElement, spp: CGFloat) -> some View {
        let barWidth = max((element.endTime - element.startTime) / spp, 20)
        let isSelected = appState.isElementSelected(element.id)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color(for: element))
                .frame(width: barWidth, height: rowHeight - 4)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? LF.gold : .clear, lineWidth: 2)
                }
            // 帧缩略图拼贴（clip 元素显示素材帧，其他元素显示图标）
            if case .clip(let clipID) = element.kind,
               let clip = FrameCache.shared.clip(id: clipID) {
                thumbnails(for: clip, barWidth: barWidth, spp: spp)
                    .frame(width: barWidth, height: rowHeight - 4)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                HStack {
                    Image(systemName: elementSymbol(element))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                    Text(element.name)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(width: barWidth, height: rowHeight - 4, alignment: .leading)
            }

            // 左边缘手柄（裁剪开始时间）
            HStack {
                Capsule()
                    .fill(LF.gold)
                    .frame(width: 4, height: rowHeight - 10)
                    .padding(.leading, 2)
                Spacer()
            }
            .frame(width: 14)
            .gesture(dragElementStart(element, spp: spp))

            // 右边缘手柄（裁剪消失时间）
            HStack {
                Spacer()
                Capsule()
                    .fill(LF.gold)
                    .frame(width: 4, height: rowHeight - 10)
                    .padding(.trailing, 2)
            }
            .frame(width: 14)
            .gesture(dragElementEnd(element, spp: spp))
        }
        .frame(width: barWidth, height: rowHeight - 4)
        .gesture(dragElement(element, spp: spp))
        .onTapGesture {
            appState.selectElement(element.id)
        }
    }

    /// 素材条内帧缩略图拼贴（按条宽平铺，最多 12 个）
    private func thumbnails(for clip: SegmentedClip, barWidth: CGFloat, spp: CGFloat) -> some View {
        let thumbW: CGFloat = 26
        let count = max(Int(barWidth / thumbW), 1)
        let indices = (0..<min(count, 12)).map { i -> Int in
            let active = clip.activeFrameIndices
            guard !active.isEmpty else { return 0 }
            let t = CGFloat(i) / CGFloat(max(count, 1)) * CGFloat(clip.frameCount)
            let idx = min(max(Int(t), 0), active.count - 1)
            return active[idx]
        }
        return HStack(spacing: 1) {
            ForEach(0..<indices.count, id: \.self) { i in
                Group {
                    if let frame = FrameCache.shared.cachedThumbnail(for: clip, index: indices[i], maxPixelSize: 60) {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.gray.opacity(0.4)
                    }
                }
                .frame(width: thumbW, height: rowHeight - 6)
                .clipped()
            }
        }
        .frame(width: barWidth, alignment: .leading)
    }

    // MARK: - 音频行

    private func audioRow(_ clip: AudioClip, spp: CGFloat) -> some View {
        let barWidth = max(clip.duration / spp, 20)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.teal.opacity(0.8))
                .frame(width: barWidth, height: rowHeight - 4)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(appState.selectedAudioID == clip.id ? LF.gold : .clear, lineWidth: 2)
                }
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                Text(String(format: "%.1f", clip.volume))
            }
            .font(.caption2)
            .padding(.horizontal, 6)
        }
        .frame(width: barWidth, height: rowHeight - 4)
        .gesture(dragAudio(clip, spp: spp))
        .onTapGesture {
            appState.selectedAudioID = clip.id
            appState.clearElementSelection()
        }
    }

    // MARK: - 播放头（可拖动）

    private func playhead(spp: CGFloat, height: CGFloat) -> some View {
        let x = appState.currentTime / spp
        return Rectangle()
            .fill(LF.gold)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                Circle()
                    .fill(LF.gold)
                    .frame(width: 10, height: 10)
                    .offset(y: rulerHeight / 2 - 2)
            }
            .offset(x: x - 1)
            .position(x: 0, y: rulerHeight + height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        appState.pause()
                        let t = value.location.x * spp
                        appState.seek(to: t)
                    }
            )
            .allowsHitTesting(true)
    }

    // MARK: - 拖动（含磁吸）

    /// 整体拖动：移动出现时间（就近磁吸对齐）
    private func dragElement(_ element: CompositionElement, spp: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition,
                      let current = comp.elements.first(where: { $0.id == element.id }) else { return }
                let delta = value.translation.width * spp
                let duration = current.endTime - current.startTime
                var newStart = min(max(current.startTime + delta, 0), comp.duration - duration)
                newStart = snap(newStart, excluding: element.id, comp: comp)
                appState.updateElement(element.id) { element in
                    element.startTime = newStart
                    element.endTime = newStart + duration
                }
            }
    }

    /// 左边缘拖动：裁剪开始时间（磁吸）
    private func dragElementStart(_ element: CompositionElement, spp: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition,
                      let current = comp.elements.first(where: { $0.id == element.id }) else { return }
                let delta = value.translation.width * spp
                var newStart = min(max(current.startTime + delta, 0), current.endTime - 0.1)
                newStart = snap(newStart, excluding: element.id, comp: comp)
                appState.updateElement(element.id) { element in
                    element.startTime = newStart
                }
            }
    }

    /// 右边缘拖动：裁剪消失时间（磁吸）
    private func dragElementEnd(_ element: CompositionElement, spp: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition,
                      let current = comp.elements.first(where: { $0.id == element.id }) else { return }
                let delta = value.translation.width * spp
                var newEnd = min(max(current.endTime + delta, current.startTime + 0.1), comp.duration)
                // 右边缘磁吸到其他元素起点/终点/播放头
                let snapPoints: [CGFloat] = [0] + comp.elements.compactMap { e in
                    e.id == element.id ? nil : [e.startTime, e.endTime]
                }.flatMap { $0 } + comp.audioClips.flatMap { [$0.startTime, $0.startTime + $0.duration] }
                let threshold: CGFloat = 0.1
                if let nearest = snapPoints.min(by: { abs($0 - newEnd) < abs($1 - newEnd) }),
                   abs(nearest - newEnd) < threshold {
                    newEnd = nearest
                }
                appState.updateElement(element.id) { element in
                    element.endTime = newEnd
                }
            }
    }

    /// 就近磁吸：吸附到轨道起点/其他元素边缘/播放头
    private func snap(_ value: CGFloat, excluding elementID: UUID, comp: Composition) -> CGFloat {
        var points: [CGFloat] = [0, appState.currentTime]
        points += comp.elements.compactMap { e in
            e.id == elementID ? nil : [e.startTime, e.endTime]
        }.flatMap { $0 }
        points += comp.audioClips.flatMap { [$0.startTime, $0.startTime + $0.duration] }
        let threshold: CGFloat = 0.1
        guard let nearest = points.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) < threshold else { return value }
        return nearest
    }

    private func dragAudio(_ clip: AudioClip, spp: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let comp = appState.composition,
                      let current = comp.audioClips.first(where: { $0.id == clip.id }) else { return }
                let delta = value.translation.width * spp
                var newStart = min(max(current.startTime + delta, 0), comp.duration - current.duration)
                let points: [CGFloat] = [0] + comp.elements.flatMap { [$0.startTime, $0.endTime] }
                let threshold: CGFloat = 0.1
                if let nearest = points.min(by: { abs($0 - newStart) < abs($1 - newStart) }),
                   abs(nearest - newStart) < threshold {
                    newStart = nearest
                }
                appState.updateAudio(clip.id) { clip in
                    clip.startTime = newStart
                }
            }
    }

    private func elementSymbol(_ element: CompositionElement) -> String {
        switch element.kind {
        case .clip: "person.crop.rectangle"
        case .decoration: "rectangle.badge.plus"
        case .effect: "sparkles"
        case .text: "textformat"
        }
    }

    private func color(for element: CompositionElement) -> Color {
        switch element.kind {
        case .clip: LF.magic.opacity(0.75)
        case .decoration: LF.gold.opacity(0.75)
        case .effect: Color.pink.opacity(0.75)
        case .text: Color.blue.opacity(0.75)
        }
    }
}
