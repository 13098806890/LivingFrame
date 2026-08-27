import LivingFrameCore
import SwiftUI

/// 编辑帧缓存：素材模式读取原始素材帧，背景模式异步渲染整张画布。
@MainActor
final class CompositeFrameCache: ObservableObject {
    @Published var frames: [Int: CGImage] = [:]
    private var renderTask: Task<Void, Never>?
    /// 缓存版本号（composition 变化时递增，触发全量刷新）
    private var version = 0

    /// 素材模式：直接读取指定素材自己的原始帧，不混入其他图层或背景。
    func rebuildForClip(_ clip: SegmentedClip, thumbSize: CGFloat = 160) {
        version += 1
        let currentVersion = version
        renderTask?.cancel()
        frames.removeAll()

        guard clip.frameCount > 0 else { return }
        let clipValue = clip
        let count = clip.frameCount

        renderTask = Task.detached(priority: .utility) {
            for i in 0..<count {
                guard !Task.isCancelled else { return }
                let image = FrameCache.shared.cachedThumbnail(
                    for: clipValue,
                    index: i,
                    maxPixelSize: thumbSize
                )
                await MainActor.run {
                    guard self.version == currentVersion else { return }
                    if let image { self.frames[i] = image }
                }
            }
        }
    }

    /// 背景模式：按工程 FPS 渲染全部图层合成后的原始画布帧。
    func rebuildForComposition(_ composition: Composition, thumbSize: CGFloat = 160) {
        version += 1
        let currentVersion = version
        renderTask?.cancel()
        frames.removeAll()

        var comp = composition
        // 编辑时必须看到被排除位置原本的合成画面，才能重新选回该帧。
        comp.excludedCompositionFrames = []
        let count = comp.frameCount
        guard count > 0, comp.fps > 0 else { return }
        let fps = comp.fps

        renderTask = Task.detached(priority: .utility) {
            let renderer = CompositionRenderer(frameMaxPixelSize: thumbSize)
            for i in 0..<count {
                guard !Task.isCancelled else { return }
                let image = renderer.render(comp, at: Double(i) / fps)
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
/// 素材模式编辑指定素材原始帧；背景模式编辑全部图层合成后的画布帧。
struct FrameGridView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cache = CompositeFrameCache()

    /// 指定素材；nil = 编辑页第一个 clip 元素。背景模式下忽略该值。
    let clipID: String?
    let editsComposition: Bool

    init(clipID: String? = nil, editsComposition: Bool = false) {
        self.clipID = clipID
        self.editsComposition = editsComposition
    }

    private var primaryClipID: String? {
        guard !editsComposition else { return nil }
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

    @State private var excluded: Set<Int> = []
    @State private var preset: FrameSelectPreset = .all
    @State private var zoomIndex: Int? = nil

    private let columns = [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5),
                           GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)]

    private var totalFrames: Int {
        editsComposition ? (appState.composition?.frameCount ?? 0) : (primaryClip?.frameCount ?? 0)
    }
    private var selectedCount: Int { totalFrames - excluded.count }

    private var detailComposition: Composition? {
        guard editsComposition, var comp = appState.composition else { return nil }
        comp.excludedCompositionFrames = []
        return comp
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 4) {
                        Text(
                            editsComposition
                                ? "去掉的合成帧由前一张合成帧填补，时间轴和音频保持不变"
                                : "去掉的素材帧由前一张素材帧填补，后续帧位置和总时长不变"
                        )
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
                // 单帧放大查看：素材模式看原始透明帧，背景模式看整张合成画面。
                if let zoom = zoomIndex, totalFrames > 0 {
                    FrameDetailView(
                        composition: detailComposition,
                        clip: editsComposition ? nil : primaryClip,
                        frameCount: totalFrames,
                        frameIndex: zoom,
                        cache: cache
                    ) {
                        zoomIndex = nil
                    }
                    .transition(.opacity)
                }
            }
            .lfNavigationTitle("编辑帧")
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
                        Text(editsComposition ? "编辑合成帧" : "编辑素材帧")
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
                        if editsComposition {
                            appState.setExcludedCompositionFrames(excluded)
                        } else if let id = primaryClipID {
                            appState.setExcludedFrames(id, excluded)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(LF.gold)
                }
            }
            .onAppear {
                if editsComposition, let comp = appState.composition {
                    excluded = comp.excludedCompositionFrames
                    for p in FrameSelectPreset.allCases {
                        if p.excludedFrames(total: comp.frameCount) == excluded {
                            preset = p; break
                        }
                    }
                    cache.rebuildForComposition(comp, thumbSize: 160)
                } else if let clip = primaryClip {
                    excluded = clip.excludedFrames
                    for p in FrameSelectPreset.allCases {
                        if p.excludedFrames(total: clip.frameCount) == clip.excludedFrames {
                            preset = p; break
                        }
                    }
                    cache.rebuildForClip(clip, thumbSize: 160)
                }
            }
            .onDisappear {
                cache.cancel()
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

/// 单帧放大查看：clip 非 nil 时显示素材原始帧，否则显示 composition 合成帧。
struct FrameDetailView: View {
    let composition: Composition?
    let clip: SegmentedClip?
    let frameCount: Int
    @State var frameIndex: Int
    @ObservedObject var cache: CompositeFrameCache
    let onClose: () -> Void
    @State private var detailImage: CGImage?

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
                    Text("第 \(frameIndex + 1) 帧 / 共 \(frameCount) 帧")
                        .font(.subheadline)
                        .foregroundStyle(LF.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                // 只异步渲染当前合成帧，避免 TabView 初始化时在主线程同步渲染全部帧。
                ZStack {
                    CheckerboardView()
                    if let image = detailImage ?? cache.frames[frameIndex] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(frameSwipeGesture)
                .task(id: frameIndex) {
                    await loadCurrentFrame()
                }
                // 帧条（小图，合成画面缓存）
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 4) {
                            ForEach(0..<frameCount, id: \.self) { index in
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
            }
        }
    }

    private var frameSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard abs(value.translation.width) > 44 else { return }
                if value.translation.width < 0, frameIndex < frameCount - 1 {
                    frameIndex += 1
                } else if value.translation.width > 0, frameIndex > 0 {
                    frameIndex -= 1
                }
            }
    }

    /// 高分辨率详情帧在后台按需渲染；切换帧时 SwiftUI 会自动取消上一项任务。
    @MainActor
    private func loadCurrentFrame() async {
        detailImage = nil
        let index = frameIndex
        let rendered: CGImage?
        if let clip {
            let clipValue = clip
            rendered = await Task.detached(priority: .userInitiated) {
                FrameCache.shared.cachedThumbnail(
                    for: clipValue,
                    index: index,
                    maxPixelSize: 800
                )
            }.value
        } else if let composition, composition.fps > 0 {
            let time = Double(index) / composition.fps
            rendered = await Task.detached(priority: .userInitiated) {
                CompositionRenderer(frameMaxPixelSize: 800).render(composition, at: time)
            }.value
        } else {
            return
        }
        guard !Task.isCancelled, index == frameIndex else { return }
        detailImage = rendered
    }
}
