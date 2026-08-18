import LivingFrameCore
import SwiftUI

/// 合成帧缓存：异步渲染合成画面缩略图，按帧索引缓存
@MainActor
final class CompositeFrameCache: ObservableObject {
    @Published var frames: [Int: CGImage] = [:]
    private var renderTask: Task<Void, Never>?
    /// 缓存版本号（composition 变化时递增，触发全量刷新）
    private var version = 0

    /// 按主素材帧序列渲染合成画面：帧 i = 主素材播放到第 i 帧时的整个画布
    /// （多素材叠加时每帧都显示全部素材 + 背景）
    func rebuildForClip(composition: Composition, clipID: String, thumbSize: CGFloat = 160) {
        version += 1
        let currentVersion = version
        renderTask?.cancel()
        frames.removeAll()

        guard let element = composition.elements.first(where: { e in
            if case .clip(let id) = e.kind { return id == clipID }; return false
        }),
        let clip = FrameCache.shared.clip(id: clipID),
        clip.frameCount > 0,
        clip.fps > 0 else { return }

        let comp = composition
        let count = clip.frameCount
        let fps = clip.fps
        let startTime = element.startTime

        renderTask = Task.detached(priority: .utility) {
            let renderer = CompositionRenderer(frameMaxPixelSize: thumbSize)
            for i in 0..<count {
                guard !Task.isCancelled else { return }
                let time = startTime + Double(i) / fps
                let image = renderer.render(comp, at: time)
                await MainActor.run {
                    guard self.version == currentVersion else { return }
                    if let image { self.frames[i] = image }
                }
            }
        }
    }

    func cancel() {
        renderTask?.cancel()
    }
}

/// 帧选择预设模式
enum FrameSelectPreset: CaseIterable {
    case all        // 全选
    case half       // 每隔一帧（~50%）
    case quarter    // 交叉排列（~25%）

    /// 循环切换到下一个模式
    var next: FrameSelectPreset {
        let all = FrameSelectPreset.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }

    /// 计算应排除的帧索引
    func excludedFrames(total: Int) -> Set<Int> {
        switch self {
        case .all:
            return []
        case .half:
            // 保留奇数索引（1,3,5...），排除偶数（0,2,4...）→ 视觉上竖条效果
            return Set((0..<total).filter { $0 % 2 == 0 })
        case .quarter:
            // 主对角线（oxxx/xoxx/xxox/xxxo/oxxx…）：第 r 行选中列 r%4，
            // 即 i % 4 == (i / 4) % 4，每行恰好 1 帧，无空行
            return Set((0..<total).filter { $0 % 4 != ($0 / 4) % 4 })
        }
    }
}

/// 预设模式图标（4×4 方格：亮=选中，暗=排除）
struct FramePresetIcon: View {
    let preset: FrameSelectPreset

    private let columns = Array(repeating: GridItem(.fixed(4.5), spacing: 1), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 1) {
            ForEach(0..<16, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(isFilled(i) ? LF.gold : LF.surface2)
                    .frame(width: 4.5, height: 4.5)
            }
        }
        .frame(width: 21, height: 21)
    }

    private func isFilled(_ i: Int) -> Bool {
        let row = i / 4
        let col = i % 4
        switch preset {
        case .all:
            // oooo / oooo / oooo / oooo 全选
            return true
        case .half:
            // x0x0 / x0x0 / x0x0 / x0x0 竖条纹（列1、3 选中）
            return col % 2 == 1
        case .quarter:
            // 主对角线（oxxx/xoxx/xxox/xxxo）
            return row == col
        }
    }
}

/// 帧网格视图（参考 ImgPlay "编辑帧"）：
/// 单素材帧选择（预设 + 手动 + 放大 + 保存），clipID 为 nil 时取编辑页主素材
struct FrameGridView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cache = CompositeFrameCache()

    /// 指定素材；nil = 编辑页第一个 clip 元素
    let clipID: String?

    init(clipID: String? = nil) {
        self.clipID = clipID
    }

    private var primaryClipID: String? {
        if let clipID { return clipID }
        return appState.composition?.elements.compactMap { e -> String? in
            guard case .clip(let id) = e.kind else { return nil }
            return id
        }.first
    }
    private var primaryClip: SegmentedClip? {
        guard let id = primaryClipID else { return nil }
        return appState.clips.first { $0.id == id }
    }

    private var primaryElement: CompositionElement? {
        guard let id = primaryClipID else { return nil }
        return appState.composition?.elements.first { e in
            if case .clip(let cid) = e.kind { return cid == id }
            return false
        }
    }

    @State private var excluded: Set<Int> = []
    @State private var preset: FrameSelectPreset = .all
    @State private var zoomIndex: Int? = nil

    private let columns = [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5),
                           GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)]

    private var totalFrames: Int { primaryClip?.frameCount ?? 0 }
    private var selectedCount: Int { totalFrames - excluded.count }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 4) {
                        Text("去掉的帧会延长保留帧的展示时间，总时长不变，音频保持同步")
                            .font(.caption2)
                            .foregroundStyle(LF.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.top, 2)
                        LazyVGrid(columns: columns, spacing: 5) {
                            ForEach(0..<totalFrames, id: \.self) { index in
                                frameCell(index)
                            }
                        }
                        .padding(.horizontal, 3)
                    }
                }
                // 单帧放大查看（合成画面）
                if let zoom = zoomIndex, let clip = primaryClip, let element = primaryElement {
                    FrameDetailView(
                        composition: appState.composition,
                        element: element,
                        clip: clip,
                        frameIndex: zoom
                    ) {
                        zoomIndex = nil
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle("编辑帧")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("编辑帧")
                            .font(.subheadline.weight(.semibold))
                        Text("\(selectedCount) / \(totalFrames) 张帧")
                            .font(.caption2)
                            .foregroundStyle(LF.textSecondary)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // 预设切换按钮（循环切换三种模式，自定义 4×4 方格图标）
                    Button {
                        let next = preset.next
                        preset = next
                        excluded = next.excludedFrames(total: totalFrames)
                    } label: {
                        FramePresetIcon(preset: preset)
                    }
                    Button("完成") {
                        if let id = primaryClipID {
                            appState.setExcludedFrames(id, excluded)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(LF.gold)
                }
            }
            .onAppear {
                if let clip = primaryClip, let comp = appState.composition {
                    excluded = clip.excludedFrames
                    for p in FrameSelectPreset.allCases {
                        if p.excludedFrames(total: clip.frameCount) == clip.excludedFrames {
                            preset = p; break
                        }
                    }
                    cache.rebuildForClip(composition: comp, clipID: clip.id, thumbSize: 160)
                }
            }
        }
    }

    private func frameCell(_ index: Int) -> some View {
        let isSelected = !excluded.contains(index)
        return ZStack(alignment: .topLeading) {
            // 合成画面缩略图（满宽等高，保证每帧等宽）
            Group {
                if let frame = cache.frames[index] {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(LF.surface2.opacity(0.3))
                        .overlay { ProgressView().scaleEffect(0.5) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 90)
            .clipped()
            // 未选中帧：深色遮罩
            if !isSelected {
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: 90)
            }
            // 编号（选中帧显示橙色编号）
            if isSelected {
                Text("\(activeDisplayIndex(index) + 1)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(LF.gold)
            }
            // ⊕ 放大镜（右下角，参考 ImgPlay）
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            zoomIndex = index
                        }
                    } label: {
                        Image(systemName: isSelected ? "plus.magnifyingglass" : "magnifyingglass")
                            .font(.callout)
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.45), in: Circle())
                            .foregroundStyle(isSelected ? LF.gold : LF.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 90)
        }
        .frame(maxWidth: .infinity, maxHeight: 90)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            // 切换选中/排除
            if excluded.contains(index) {
                excluded.remove(index)
            } else {
                excluded.insert(index)
            }
            for p in FrameSelectPreset.allCases {
                if p.excludedFrames(total: totalFrames) == excluded {
                    preset = p
                    break
                }
            }
        }
    }

    /// 选中帧的显示序号（去掉被排除的帧后的排名）
    private func activeDisplayIndex(_ index: Int) -> Int {
        (0..<index).filter { !excluded.contains($0) }.count
    }
}

/// 单帧放大查看（全屏，合成画面，支持左右切换）
struct FrameDetailView: View {
    let composition: Composition?
    let element: CompositionElement
    let clip: SegmentedClip
    @State var frameIndex: Int
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // 导航栏
                HStack {
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(LF.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("第 \(frameIndex + 1) 帧 / 共 \(clip.frameCount) 帧")
                        .font(.subheadline)
                        .foregroundStyle(LF.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                // 帧图像（合成画面，支持左右滑动切换）
                TabView(selection: $frameIndex) {
                    ForEach(0..<clip.frameCount, id: \.self) { index in
                        ZStack {
                            CheckerboardView()
                            if let image = renderCompositeFrame(index) {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .scaledToFit()
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // 帧条（小图，合成画面缓存）
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(0..<clip.frameCount, id: \.self) { index in
                                Button { frameIndex = index } label: {
                                    Group {
                                        if let image = cache.frames[index] {
                                            Image(decorative: image, scale: 1)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            Color.gray
                                        }
                                    }
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay {
                                        if frameIndex == index {
                                            RoundedRectangle(cornerRadius: 4).stroke(LF.gold, lineWidth: 2)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: 52)
                    .onChange(of: frameIndex) { _, idx in
                        withAnimation { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
                .padding(.bottom, 8)
                .onAppear {
                    if let composition {
                        cache.rebuildForClip(composition: composition, clipID: clip.id, thumbSize: 80)
                    }
                }
            }
        }
    }

    /// 渲染主素材第 index 帧时刻的合成画面（所有素材 + 背景）
    private func renderCompositeFrame(_ index: Int) -> CGImage? {
        guard let composition, clip.fps > 0 else { return nil }
        let time = element.startTime + Double(index) / clip.fps
        return compositeRenderer.render(composition, at: time)
    }

    private let compositeRenderer = CompositionRenderer(frameMaxPixelSize: 800)
    @StateObject private var cache = CompositeFrameCache()
}
