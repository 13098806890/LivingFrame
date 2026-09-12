import LivingFrameCore
import SwiftUI
import UIKit

/// 独立的拼接编辑器：选完图片后直接在这里完成布局和取景，不再依赖先点背景图再打开检查器。
struct CollageEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// 已存在于工程中的背景元素。取消时只回滚本次会话新加入的元素。
    let existingElementIDs: [UUID]

    @State private var elementIDs: [UUID] = []
    @State private var temporaryElementIDs: [UUID] = []
    @State private var activeElementID: UUID?
    @State private var focusedPartition: Int?
    /// 没有图片时也要能先编辑分割线；图片加入后再把这份布局应用到整组元素。
    @State private var layoutSettings = BackgroundElementSettings()
    @State private var isDividerLayoutLocked = false
    @State private var didFinish = false
    @State private var showAssetPicker = false

    init(existingElementIDs: [UUID] = []) {
        self.existingElementIDs = existingElementIDs
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sourceStrip
                    collageWorkspace
                    collageControls
                }
                .padding(12)
            }
            .scrollIndicators(.hidden)
            .lfNavigationTitle("拼接编辑器")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        didFinish = true
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(LF.actionPrimary)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showAssetPicker) {
            AssetPickerView(
                collageOnly: true,
                onCollageSelection: appendMedia
            )
            .environmentObject(appState)
        }
        .onAppear {
            appState.pause()
            startSessionIfNeeded()
        }
        .onDisappear {
            appState.pause()
            if !didFinish, !showAssetPicker {
                appState.removeTemporaryCollageElements(temporaryElementIDs)
            }
        }
    }

    @ViewBuilder
    private var collageWorkspace: some View {
        if let composition = appState.composition {
            BackgroundEditingPreview(
                items: collagePreviewItems,
                layoutSettings: collageLayoutSettings,
                activeElementSettings: activeElement?.backgroundSettings,
                focusedPartition: focusedPartition,
                canvasAspect: composition.canvasRect.width / max(composition.canvasRect.height, 1),
                canvasSize: composition.canvasRect.size,
                activeElementID: activeElementID,
                isDividerLayoutLocked: isDividerLayoutLocked,
                onElementTap: { elementID, partition in
                    activeElementID = elementID
                    appState.selectElement(elementID)
                    // 保留点击命中的区域，选中素材后立即提供“移出区域”操作。
                    focusedPartition = partition
                },
                onPartitionTap: { partition in
                    // 点击空区域只聚焦区域；添加/移除统一通过下方操作栏完成，
                    // 避免和点击区域内已有素材的选中行为冲突。
                    focusedPartition = partition
                },
                onDividerOffsetChange: { dividerIndex, offset in
                    guard !isDividerLayoutLocked else { return }
                    if elementIDs.isEmpty {
                        updateDraftLayout { settings in
                            guard settings.dividerLines.indices.contains(dividerIndex) else { return }
                            settings.dividerLines[dividerIndex].offset = BackgroundDividerGeometry.clampedOffset(offset)
                        }
                    } else {
                        appState.setCollageDividerOffset(
                            elementIDs,
                            dividerIndex: dividerIndex,
                            offset: offset
                        )
                    }
                },
                onDividerPivotChange: { dividerIndex, pivot in
                    guard !isDividerLayoutLocked else { return }
                    if elementIDs.isEmpty {
                        updateDraftLayout { settings in
                            guard settings.dividerLines.indices.contains(dividerIndex) else { return }
                            settings.dividerLines[dividerIndex].pivot = BackgroundDividerGeometry.clampedPivot(pivot)
                        }
                    } else {
                        appState.setCollageDividerPivot(
                            elementIDs,
                            dividerIndex: dividerIndex,
                            pivot
                        )
                    }
                },
                onCropScaleChange: { scale in
                    guard let activeElementID else { return }
                    appState.setBackgroundCropScale(activeElementID, scale)
                },
                onCropOffsetChange: { offset in
                    guard let activeElementID else { return }
                    appState.setBackgroundCropOffset(activeElementID, offset)
                }
            )

            if let focusedPartition {
                partitionActionBar(for: focusedPartition)
            }
        } else {
            Text("正在准备拼接画布…")
                .font(.subheadline)
                .foregroundStyle(LF.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
        }
    }

    private var collagePreviewItems: [BackgroundEditingPreviewItem] {
        collageElements.compactMap { element in
            guard case .background(let mediaID) = element.kind,
                  let frame = BackgroundStore.shared.loadFrame(
                      named: mediaID,
                      at: appState.currentTime
                  ) else { return nil }
            return BackgroundEditingPreviewItem(
                id: element.id,
                frame: frame,
                settings: element.backgroundSettings ?? BackgroundElementSettings(),
                zIndex: element.zIndex
            )
        }
    }

    private var sourceStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("拼接素材")
                .font(.subheadline.weight(.semibold))
            Text("点击素材选中；区域归属和图层顺序都可以直接在卡片上调整。")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(elementIDs, id: \.self) { elementID in
                        if let element = collageElements.first(where: { $0.id == elementID }),
                           case .background(let mediaID) = element.kind,
                           let media = appState.backgroundMedia.first(where: { $0.id == mediaID }) {
                            CollageSourceChip(
                                item: media,
                                assignedPartitions: element.backgroundSettings?.resolvedAssignedPartitions ?? [],
                                layerIndex: collageLayerOrder.firstIndex(where: { $0.id == elementID }).map { $0 + 1 } ?? 1,
                                layerOptions: collageLayerOptions,
                                isSelected: elementID == activeElement?.id,
                                canDuplicate: true
                            ) {
                                activeElementID = elementID
                                appState.selectElement(elementID)
                            } onSelectLayer: { layerID in
                                selectCollageElement(layerID)
                            } onMoveUp: {
                                appState.moveCollageElementZ(elementID, up: true)
                            } onMoveDown: {
                                appState.moveCollageElementZ(elementID, up: false)
                            } onDuplicate: {
                                duplicateMediaAsIndependentInstance(mediaID: mediaID)
                            } onDelete: {
                                deleteCollageElement(elementID)
                            }
                        }
                    }

                    Button {
                        showAssetPicker = true
                    } label: {
                        Label("添加素材", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(LF.actionPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private var collageControls: some View {
        let settings = collageLayoutSettings
        let selectedSettings = activeElement?.backgroundSettings ?? settings
        VStack(alignment: .leading, spacing: 8) {
            BackgroundDividerControls(
                settings: selectedSettings,
                canvasRect: appState.composition?.canvasRect
                    ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                isDividerLayoutLocked: collageDividerLayoutLockBinding,
                onAddDivider: {
                    if elementIDs.isEmpty {
                        updateDraftLayout { settings in
                            guard settings.dividerLines.count < BackgroundPartitionGeometry.maximumDividerCount else { return }
                            let angle = settings.dividerLines.last.map { $0.angle + 90 } ?? 90
                            settings.dividerLines.append(BackgroundDivider(angle: angle))
                        }
                    } else {
                        appState.addCollageDividerLine(elementIDs)
                    }
                },
                onRemoveDivider: { dividerIndex in
                    if elementIDs.isEmpty {
                        updateDraftLayout { settings in
                            guard settings.dividerLines.indices.contains(dividerIndex) else { return }
                            settings.dividerLines.remove(at: dividerIndex)
                        }
                    } else {
                        appState.removeCollageDividerLine(elementIDs, dividerIndex: dividerIndex)
                    }
                },
                onAngleChange: { dividerIndex, angle in
                    if elementIDs.isEmpty {
                        updateDraftLayout { settings in
                            updateDraftDividerAngle(
                                &settings,
                                dividerIndex: dividerIndex,
                                angle: angle
                            )
                        }
                    } else {
                        appState.setCollageDividerAngle(
                            elementIDs,
                            dividerIndex: dividerIndex,
                            angle
                        )
                    }
                },
                onPartitionSelect: { partition in
                    focusedPartition = partition
                    if let activeElement {
                        appState.toggleBackgroundPartition(activeElement.id, partition)
                    } else {
                        updateDraftLayout {
                            $0.selectedPartition = partition
                            $0.assignedPartitions = [partition]
                        }
                    }
                }
            )

            if let activeElement {
                if let source = appState.playbackSource(for: activeElement) {
                    ElementPlaybackControls(element: activeElement, source: source)
                }
                cropControl(elementID: activeElement.id, settings: selectedSettings)
            } else {
                Text("先添加分割线，再选择图片填入对应区域。")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }
        }
        .padding(10)
        .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var collageDividerLayoutLockBinding: Binding<Bool> {
        Binding(
            get: { isDividerLayoutLocked },
            set: { locked in
                isDividerLayoutLocked = locked
                if elementIDs.isEmpty {
                    updateDraftLayout { $0.isDividerLayoutLocked = locked }
                } else {
                    appState.setCollageDividerLayoutLocked(elementIDs, locked)
                }
            }
        )
    }

    private func cropControl(
        elementID: UUID,
        settings: BackgroundElementSettings
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("图片缩放")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
                Spacer()
                Text(String(format: "%.1f×", settings.cropScale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LF.textSecondary)
            }
            Slider(value: Binding(
                get: { Double(settings.cropScale) },
                set: { appState.setBackgroundCropScale(elementID, CGFloat($0)) }
            ), in: Double(BackgroundElementSettings.minimumCropScale)...Double(BackgroundElementSettings.maximumCropScale), step: 0.05)
            .tint(LF.actionPrimary)

            HStack {
                Button("重置") {
                    appState.setBackgroundCropScale(elementID, 1)
                    appState.setBackgroundCropOffset(elementID, .zero)
                }
                .buttonStyle(.bordered)

                Button("旋转90°") {
                    appState.rotateBackground90(elementID)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var collageElements: [CompositionElement] {
        guard let composition = appState.composition else { return [] }
        return elementIDs.compactMap { id in
            composition.elements.first(where: { $0.id == id })
        }
    }

    /// 图层栏统一使用“前景到后景”的顺序显示，避免用户需要猜测箭头的方向。
    private var collageLayerOrder: [CompositionElement] {
        collageElements.sorted {
            if $0.zIndex != $1.zIndex { return $0.zIndex > $1.zIndex }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private var collageLayerOptions: [CollageLayerOption] {
        collageLayerOrder.enumerated().map { index, element in
            CollageLayerOption(
                id: element.id,
                title: "图层 \(index + 1)",
                index: index + 1,
                isSelected: element.id == activeElementID
            )
        }
    }

    private func selectCollageElement(_ elementID: UUID) {
        activeElementID = elementID
        appState.selectElement(elementID)
    }

    private var activeElement: CompositionElement? {
        if let activeElementID {
            return collageElements.first(where: { $0.id == activeElementID })
        }
        return collageElements.first
    }

    private var collageLayoutSettings: BackgroundElementSettings {
        collageElements.first?.backgroundSettings ?? layoutSettings
    }

    private func startSessionIfNeeded() {
        guard elementIDs.isEmpty else { return }
        let ids = existingElementIDs
        elementIDs = ids
        if !ids.isEmpty {
            _ = appState.ensureCollageGroup(ids)
            appState.normalizeCollageLayout(ids)
            appState.normalizeCollageBackgroundTiming(ids)
            layoutSettings = collageElements.first?.backgroundSettings ?? BackgroundElementSettings()
            isDividerLayoutLocked = layoutSettings.isDividerLayoutLocked
        } else {
            isDividerLayoutLocked = layoutSettings.isDividerLayoutLocked
        }
        activeElementID = ids.first
        if let first = ids.first {
            appState.selectElement(first)
        } else {
            appState.clearElementSelection()
        }
    }

    private func appendMedia(_ mediaIDs: [String]) {
        let layout = activeElement?.backgroundSettings ?? collageLayoutSettings
        guard !mediaIDs.isEmpty else { return }
        let groupID = collageElements.compactMap(\.collageGroupID).first ?? UUID()
        let addedIDs = appState.addBackgroundElementsToCollage(
            mediaIDs: mediaIDs,
            groupID: groupID
        )
        guard !addedIDs.isEmpty else { return }
        appState.applyCollageLayout(layout, to: addedIDs)
        isDividerLayoutLocked = layout.isDividerLayoutLocked
        elementIDs.append(contentsOf: addedIDs)
        temporaryElementIDs.append(contentsOf: addedIDs)
        activeElementID = addedIDs.first
        appState.normalizeCollageBackgroundTiming(elementIDs)
        if let activeElementID {
            appState.selectElement(activeElementID)
        }
    }

    @ViewBuilder
    private func partitionActionBar(for partition: Int) -> some View {
        if let activeElement {
            let isAssigned = activeElement.backgroundSettings?.resolvedAssignedPartitions.contains(partition) == true
            HStack(spacing: 8) {
                if case .background(let mediaID) = activeElement.kind,
                   let frame = BackgroundStore.shared.loadFrame(named: mediaID, at: 0) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 34, height: 27)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Image(systemName: isAssigned ? "checkmark" : "plus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 13, height: 13)
                            .background(isAssigned ? LF.selectionStroke : LF.actionPrimary, in: Circle())
                            .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 0.7) }
                            .offset(x: 3, y: 3)
                    }
                    .frame(width: 34, height: 27)
                    .accessibilityLabel(isAssigned ? "当前素材已在此区域" : "当前素材待添加到此区域")
                }
                Image(systemName: isAssigned ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(isAssigned ? LF.selectionStroke : LF.actionPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("区域 \(partition + 1)")
                        .font(.caption.weight(.semibold))
                    Text(isAssigned ? "当前素材已在此区域" : "点击按钮添加到这里")
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                }
                Spacer(minLength: 8)
                Button(isAssigned ? "移除" : "点击添加") {
                    appState.toggleBackgroundPartition(activeElement.id, partition)
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(isAssigned ? LF.header : LF.actionPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Text("先选择一个拼接素材，再添加到区域 \(partition + 1)。")
                .font(.caption)
                .foregroundStyle(LF.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    /// 复用已有媒体创建一个新的独立实例。它仍引用同一个媒体 ID，
    /// 但拥有独立取景参数，并等待用户选择要覆盖的区域。
    private func duplicateMediaAsIndependentInstance(mediaID: String) {
        let layout = collageLayoutSettings

        let groupID = collageElements.compactMap(\.collageGroupID).first ?? UUID()
        let addedIDs = appState.addBackgroundElementsToCollage(
            mediaIDs: [mediaID],
            groupID: groupID
        )
        guard let addedID = addedIDs.first else { return }
        appState.applyCollageLayout(layout, to: addedIDs)
        appState.normalizeCollageBackgroundTiming(elementIDs + addedIDs)
        elementIDs.append(addedID)
        temporaryElementIDs.append(addedID)
        activeElementID = addedID
        appState.selectElement(addedID)
    }

    private func deleteCollageElement(_ elementID: UUID) {
        guard elementIDs.contains(elementID) else { return }
        appState.deleteElement(elementID)
        elementIDs.removeAll { $0 == elementID }
        temporaryElementIDs.removeAll { $0 == elementID }

        guard activeElementID == elementID else { return }
        activeElementID = elementIDs.first
        if let nextID = activeElementID {
            appState.selectElement(nextID)
        } else {
            appState.clearElementSelection()
        }
    }

    private func updateDraftLayout(_ mutate: (inout BackgroundElementSettings) -> Void) {
        var updated = layoutSettings
        mutate(&updated)
        updated.synchronizeLegacySplitCount()
        if let first = updated.dividerLines.first {
            updated.dividerAngle = first.angle
            updated.primaryDividerOffset = first.offset
            updated.primaryDividerPivot = first.pivot
        }
        if updated.dividerLines.count > 1 {
            let second = updated.dividerLines[1]
            updated.secondaryDividerAngle = second.angle
            updated.secondaryDividerOffset = second.offset
            updated.secondaryDividerPivot = second.pivot
        }
        layoutSettings = updated
    }

    /// 空画布阶段也必须以当前控制点为旋转圆心；改变角度时反算 offset，保持 pivot 的画布坐标不变。
    private func updateDraftDividerAngle(
        _ settings: inout BackgroundElementSettings,
        dividerIndex: Int,
        angle: CGFloat
    ) {
        guard settings.dividerLines.indices.contains(dividerIndex) else { return }
        let rect = appState.composition?.canvasRect
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let oldPivot = BackgroundPartitionGeometry.pivot(
            for: dividerIndex,
            in: rect,
            settings: settings,
            coordinateSpace: .coreImage
        )

        settings.dividerLines[dividerIndex].angle = angle
        if dividerIndex == 0 {
            settings.dividerAngle = angle
        } else if dividerIndex == 1 {
            settings.secondaryDividerAngle = angle
        }

        let newNormal = BackgroundPartitionGeometry.normal(
            for: dividerIndex,
            settings: settings,
            coordinateSpace: .coreImage
        )
        let newOffset = BackgroundDividerGeometry.offset(
            keeping: oldPivot,
            normal: newNormal,
            in: rect
        )
        let normalizedPivot = BackgroundPartitionGeometry.normalizedPivot(
            at: oldPivot,
            in: rect,
            coordinateSpace: .coreImage
        )
        settings.dividerLines[dividerIndex].offset = newOffset
        settings.dividerLines[dividerIndex].pivot = normalizedPivot
        if dividerIndex == 0 {
            settings.primaryDividerOffset = newOffset
            settings.primaryDividerPivot = normalizedPivot
        } else if dividerIndex == 1 {
            settings.secondaryDividerOffset = newOffset
            settings.secondaryDividerPivot = normalizedPivot
        }
    }
}

struct BackgroundEditingPreviewItem: Identifiable {
    let id: UUID
    let frame: CGImage
    let settings: BackgroundElementSettings
    let zIndex: Int
}

/// 拼接器唯一的编辑画面：所有照片同时显示，分割线由整组拼接共享，
/// 当前选中的照片只改变自己的取景参数。
struct BackgroundEditingPreview: View {
    let items: [BackgroundEditingPreviewItem]
    let layoutSettings: BackgroundElementSettings
    let activeElementSettings: BackgroundElementSettings?
    let focusedPartition: Int?
    let canvasAspect: CGFloat
    let canvasSize: CGSize
    let activeElementID: UUID?
    let isDividerLayoutLocked: Bool
    let onElementTap: (UUID, Int) -> Void
    let onPartitionTap: (Int) -> Void
    let onDividerOffsetChange: (Int, CGFloat) -> Void
    let onDividerPivotChange: (Int, CGPoint) -> Void
    let onCropScaleChange: (CGFloat) -> Void
    let onCropOffsetChange: (CGPoint) -> Void

    private enum CanvasDragMode {
        case divider(Int)
        case pivot(Int)
        case image
    }

    @State private var activeDividerIndex: Int?
    @State private var dividerOffsetAtDragStart: CGFloat = 0
    @State private var activePivotIndex: Int?
    @State private var imageDragStartOffset: CGPoint?
    @State private var imageScaleStart: CGFloat?
    @State private var didMoveCanvasDuringDrag = false

    private var sharedSettings: BackgroundElementSettings {
        items.first?.settings ?? layoutSettings
    }

    private var activeItem: BackgroundEditingPreviewItem? {
        items.first(where: { $0.id == activeElementID }) ?? items.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(isDividerLayoutLocked
                ? "编辑画面 · 分割线已固定 · 拖动图片调整取景"
                : "编辑画面 · 拖动图片调整取景 · 拖动分割线调整布局")
                .font(.caption2)
                .foregroundStyle(LF.textSecondary)

            GeometryReader { geometry in
                let rect = CGRect(origin: .zero, size: geometry.size)
                let minimumZIndex = items.map(\.zIndex).min() ?? 0
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white)
                        .zIndex(-1)

                    ForEach(items) { item in
                        Image(decorative: item.frame, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .rotationEffect(.degrees(Double(item.settings.rotationQuarterTurns * 90)))
                            .scaleEffect(rotationFillScale(item.settings, in: geometry.size))
                            .scaleEffect(item.settings.cropScale)
                            .offset(
                                x: item.settings.cropOffset.x * geometry.size.width / max(canvasSize.width, 1),
                                y: -item.settings.cropOffset.y * geometry.size.height / max(canvasSize.height, 1)
                            )
                            .clipped()
                            .clipShape(BackgroundPartitionShape(settings: item.settings))
                            // Composition 的 zIndex 可能是负数；转换成从 0 开始的
                            // 相对值，避免素材被白色画布底板压到下面。
                            .zIndex(Double(item.zIndex - minimumZIndex))
                    }

                    if let focusedPartition {
                        let settings = focusedPartitionSettings(for: focusedPartition)
                        BackgroundPartitionShape(settings: settings)
                            .fill(LF.selectionFill.opacity(0.14))
                            .overlay {
                                BackgroundPartitionShape(settings: settings)
                                    .stroke(LF.selectionStroke.opacity(0.72), lineWidth: 1.5)
                            }
                            .allowsHitTesting(false)
                            .zIndex(900)
                    }

                    BackgroundDividerShape(settings: sharedSettings)
                        .stroke(LF.header.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .zIndex(1000)

                    if !sharedSettings.dividerLines.isEmpty {
                        ForEach(0..<dividerCount, id: \.self) { index in
                            dividerHandle(index: index, in: rect, isEnabled: !isDividerLayoutLocked)
                        }

                        ForEach(0..<BackgroundPartitionGeometry.regionCount(
                            for: sharedSettings,
                            in: rect
                        ), id: \.self) { partition in
                            let isActive = activeElementSettings?.resolvedAssignedPartitions.contains(partition) == true
                            let isFilled = items.contains {
                                $0.settings.resolvedAssignedPartitions.contains(partition)
                            }
                            Text("区域 \(partition + 1)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isActive ? LF.selectionText : LF.textPrimary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    isActive
                                        ? LF.selectionFill
                                        : (isFilled ? LF.surface2.opacity(0.88) : LF.surface2.opacity(0.58)),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(
                                            isActive ? LF.selectionStroke : LF.header.opacity(0.3),
                                            lineWidth: isActive ? 1.5 : 1
                                        )
                                }
                                .position(regionLabelPosition(partition, in: rect))
                                .zIndex(1001)
                                .allowsHitTesting(false)
                        }
                    }

                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(LF.header.opacity(0.45), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard !didMoveCanvasDuringDrag else {
                        didMoveCanvasDuringDrag = false
                        return
                    }
                    if let partition = partition(at: location, in: rect) {
                        if let element = elementToSelect(at: location, in: partition, canvasRect: rect) {
                            onElementTap(element.id, partition)
                        } else {
                            onPartitionTap(partition)
                        }
                    }
                }
                // 拼接画布嵌在外层 ScrollView 中；拖动素材时必须优先由画布
                // 消费手势，否则竖向移动会被 ScrollView 抢走，看起来像素材不能移动。
                .highPriorityGesture(canvasDragGesture(in: rect))
                .simultaneousGesture(imageMagnifyGesture())
            }
            .aspectRatio(canvasAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
    }

    private var dividerCount: Int {
        sharedSettings.dividerLines.count
    }

    private func rotationFillScale(_ settings: BackgroundElementSettings, in size: CGSize) -> CGFloat {
        let turns = ((settings.rotationQuarterTurns % 4) + 4) % 4
        guard turns % 2 == 1 else { return 1 }
        return max(size.width / max(size.height, 1), size.height / max(size.width, 1))
    }

    private func regionLabelPosition(_ partition: Int, in rect: CGRect) -> CGPoint {
        var settings = sharedSettings
        settings.selectedPartition = partition
        return BackgroundPartitionShape.samplePoint(
            settings: settings,
            in: rect
        )
    }

    private func focusedPartitionSettings(for partition: Int) -> BackgroundElementSettings {
        var settings = sharedSettings
        settings.selectedPartition = partition
        settings.assignedPartitions = [partition]
        return settings
    }

    private func partition(at point: CGPoint, in rect: CGRect) -> Int? {
        BackgroundPartitionGeometry.partition(at: point, settings: sharedSettings, in: rect)
    }

    /// 只有实际覆盖触点的素材才是候选；同一区域重叠时再按 zIndex 从前到后排序。
    private func elements(
        in partition: Int,
        at point: CGPoint? = nil,
        canvasRect: CGRect? = nil
    ) -> [BackgroundEditingPreviewItem] {
        items
            .filter { $0.settings.resolvedAssignedPartitions.contains(partition) }
            .filter { item in
                guard let point, let canvasRect else { return true }
                return imageBounds(for: item, in: canvasRect).contains(point)
            }
            .sorted {
                if $0.zIndex != $1.zIndex { return $0.zIndex > $1.zIndex }
                return $0.id.uuidString > $1.id.uuidString
            }
    }

    /// 点击只命中触点下方实际显示的素材；多个素材重叠时由 zIndex 决定前后。
    private func elementToSelect(
        at point: CGPoint,
        in partition: Int,
        canvasRect: CGRect
    ) -> BackgroundEditingPreviewItem? {
        let candidates = elements(in: partition, at: point, canvasRect: canvasRect)
        return candidates.first
    }

    /// 与预览画面的缩放、旋转和取景偏移保持一致的图片命中范围。
    private func imageBounds(
        for item: BackgroundEditingPreviewItem,
        in rect: CGRect
    ) -> CGRect {
        let sourceSize = CGSize(
            width: CGFloat(item.frame.width),
            height: CGFloat(item.frame.height)
        )
        let fillScale = max(
            rect.width / max(sourceSize.width, 1),
            rect.height / max(sourceSize.height, 1)
        )
        var size = CGSize(
            width: sourceSize.width * fillScale,
            height: sourceSize.height * fillScale
        )
        let turns = ((item.settings.rotationQuarterTurns % 4) + 4) % 4
        if turns % 2 == 1 {
            size = CGSize(width: size.height, height: size.width)
        }
        let rotationScale = rotationFillScale(item.settings, in: rect.size)
        size.width *= rotationScale * item.settings.cropScale
        size.height *= rotationScale * item.settings.cropScale

        let center = CGPoint(
            x: rect.midX + item.settings.cropOffset.x * rect.width / max(canvasSize.width, 1),
            y: rect.midY - item.settings.cropOffset.y * rect.height / max(canvasSize.height, 1)
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    @ViewBuilder
    private func dividerHandle(index: Int, in rect: CGRect, isEnabled: Bool) -> some View {
        // 同一个控制点同时是分割线的旋转中心；分割线其他位置仍用于平行移动。
        let point = BackgroundPartitionGeometry.pivot(
            for: index,
            in: rect,
            settings: sharedSettings,
            coordinateSpace: .screen
        )
        let isActive = activePivotIndex == index
        Circle()
            .fill(isActive && isEnabled ? LF.gold : LF.header.opacity(isEnabled ? 1 : 0.5))
            .frame(width: isActive ? 24 : 20, height: isActive ? 24 : 20)
            .overlay {
                Image(systemName: isEnabled ? "scope" : "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay {
                Circle().stroke(.white.opacity(0.85), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isEnabled ? 0.25 : 0.12), radius: 2, y: 1)
            .position(point)
            .zIndex(2000)
            .contentShape(Circle().inset(by: -4))
            .allowsHitTesting(isEnabled)
            .highPriorityGesture(
                // 圆心点击只用于选中/聚焦，必须有明确拖动距离后才改变圆心，
                // 避免点击区域时因为命中圆心的扩大区域而让圆心轻微跳动。
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        guard isEnabled else { return }
                        activePivotIndex = index
                        let projected = BackgroundPartitionGeometry.projectedPivot(
                            at: value.location,
                            for: index,
                            settings: sharedSettings,
                            in: rect,
                            coordinateSpace: .screen
                        )
                        let pivot = BackgroundPartitionGeometry.normalizedPivot(
                            at: projected,
                            in: rect,
                            coordinateSpace: .screen
                        )
                        onDividerPivotChange(index, pivot)
                    }
                    .onEnded { _ in
                        if activePivotIndex == index {
                            activePivotIndex = nil
                        }
                    }
            )
    }

    private func canvasDragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let mode: CanvasDragMode
                if let activeDividerIndex {
                    guard !isDividerLayoutLocked else { return }
                    mode = .divider(activeDividerIndex)
                } else if let activePivotIndex {
                    guard !isDividerLayoutLocked else { return }
                    mode = .pivot(activePivotIndex)
                } else if !isDividerLayoutLocked,
                          let pivotIndex = pivotIndex(near: value.startLocation, in: rect) {
                    activePivotIndex = pivotIndex
                    mode = .pivot(pivotIndex)
                } else if !isDividerLayoutLocked,
                          let dividerIndex = dividerIndex(near: value.startLocation, in: rect) {
                    activeDividerIndex = dividerIndex
                    dividerOffsetAtDragStart = BackgroundDividerGeometry.offset(
                        for: dividerIndex,
                        settings: sharedSettings
                    )
                    mode = .divider(dividerIndex)
                } else if imageDragStartOffset != nil {
                    // 素材移动后，原始起点可能已经不在新的图片范围内；
                    // 一旦手势已经确认是素材拖动，就必须保持到手指抬起。
                    mode = .image
                } else {
                    // 锁定布局时，分割线区域不响应拖动；素材区域仍保持可移动。
                    if isDividerLayoutLocked,
                       (pivotIndex(near: value.startLocation, in: rect) != nil
                        || dividerIndex(near: value.startLocation, in: rect) != nil) {
                        return
                    }
                    guard let activeItem,
                          imageBounds(for: activeItem, in: rect).contains(value.startLocation) else {
                        return
                    }
                    mode = .image
                }

                if hypot(value.translation.width, value.translation.height) >= 8 {
                    didMoveCanvasDuringDrag = true
                }

                switch mode {
                case .pivot(let index):
                    let projected = BackgroundPartitionGeometry.projectedPivot(
                        at: value.location,
                        for: index,
                        settings: sharedSettings,
                        in: rect,
                        coordinateSpace: .screen
                    )
                    let pivot = BackgroundPartitionGeometry.normalizedPivot(
                        at: projected,
                        in: rect,
                        coordinateSpace: .screen
                    )
                    // 圆心模式只写入 pivot，绝不写入 offset，因此拖动时分割线不会平移。
                    onDividerPivotChange(index, pivot)
                case .divider(let index):
                    let normal = BackgroundPartitionShape.normal(
                        for: index,
                        settings: sharedSettings
                    )
                    let extent = BackgroundDividerGeometry.extent(in: rect, normal: normal)
                    guard extent > 0.0001 else { return }
                    let projectedTranslation = value.translation.width * normal.x
                        + value.translation.height * normal.y
                    onDividerOffsetChange(
                        index,
                        BackgroundDividerGeometry.clampedOffset(
                            dividerOffsetAtDragStart + projectedTranslation / extent
                        )
                    )
                case .image:
                    guard let activeItem else { return }
                    let startOffset = imageDragStartOffset ?? activeItem.settings.cropOffset
                    imageDragStartOffset = startOffset
                    let dx = value.translation.width * canvasSize.width / max(rect.width, 1)
                    let dy = -value.translation.height * canvasSize.height / max(rect.height, 1)
                    onCropOffsetChange(CGPoint(x: startOffset.x + dx, y: startOffset.y + dy))
                }
            }
            .onEnded { _ in
                activeDividerIndex = nil
                activePivotIndex = nil
                dividerOffsetAtDragStart = 0
                imageDragStartOffset = nil
                if didMoveCanvasDuringDrag {
                    // 点击手势可能在拖动结束后同一轮事件中回调；保留标记到该事件结束，
                    // 再清理，避免拖动素材的抬手被误判为区域点击。
                    DispatchQueue.main.async {
                        didMoveCanvasDuringDrag = false
                    }
                }
            }
    }

    private func imageMagnifyGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard let activeItem else { return }
                let startScale = imageScaleStart ?? activeItem.settings.cropScale
                imageScaleStart = startScale
                onCropScaleChange(min(
                    max(startScale * value, BackgroundElementSettings.minimumCropScale),
                    BackgroundElementSettings.maximumCropScale
                ))
            }
            .onEnded { _ in
                imageScaleStart = nil
            }
    }

    private func dividerIndex(near point: CGPoint, in rect: CGRect) -> Int? {
        // 命中范围只略大于可见分割线，避免区域内拖动素材时误触发分割线移动。
        let threshold = min(28, max(16, min(rect.width, rect.height) * 0.06))
        return BackgroundPartitionGeometry.dividerIndex(
            near: point,
            settings: sharedSettings,
            in: rect,
            threshold: threshold
        )
    }

    private func pivotIndex(near point: CGPoint, in rect: CGRect) -> Int? {
        // 命中范围只略大于圆心本身，避免区域点击被误判成圆心拖动。
        let threshold = max(14, min(18, min(rect.width, rect.height) * 0.05))
        let count = dividerCount
        guard count > 0 else { return nil }
        let candidates = (0..<count).map { index in
            let pivot = BackgroundPartitionGeometry.pivot(
                for: index,
                in: rect,
                settings: sharedSettings,
                coordinateSpace: .screen
            )
            let distance = hypot(point.x - pivot.x, point.y - pivot.y)
            return (index, distance)
        }
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= threshold else {
            return nil
        }
        return nearest.0
    }
}

/// 单张素材与拼接编辑器共用的分割线、区域和锁定状态控制面板。
struct BackgroundDividerControls: View {
    let settings: BackgroundElementSettings
    let canvasRect: CGRect
    @Binding var isDividerLayoutLocked: Bool
    let onAddDivider: () -> Void
    let onRemoveDivider: (Int) -> Void
    let onAngleChange: (Int, CGFloat) -> Void
    let onPartitionSelect: (Int) -> Void

    private var dividerEditingEnabled: Bool { !isDividerLayoutLocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("分割线布局")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LF.textSecondary)
                Spacer()
                Picker("分割线布局", selection: $isDividerLayoutLocked) {
                    Text("编辑").tag(false)
                    Text("固定").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 116)
                .accessibilityLabel("分割线布局状态")
            }

            HStack(spacing: 6) {
                Text(isDividerLayoutLocked ? "已固定" : "可编辑")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isDividerLayoutLocked ? LF.textSecondary : LF.actionPrimary)
                Spacer()
                Button(action: onAddDivider) {
                    Label("添加分割线", systemImage: "plus")
                        .font(.caption2.weight(.semibold))
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(LF.actionPrimary)
                .disabled(!dividerEditingEnabled || settings.dividerLines.count >= BackgroundPartitionGeometry.maximumDividerCount)
            }

            Label(
                isDividerLayoutLocked
                    ? "分割线已固定；切换到“编辑”后可继续调整，素材仍可移动和缩放。"
                    : "拖动分割线上的控制点，可沿线移动旋转中心；调整角度时，分割线会以该点为圆心旋转。",
                systemImage: "info.circle"
            )
            .font(.caption2)
            .foregroundStyle(LF.textSecondary)
            .lineLimit(2)

            if settings.dividerLines.isEmpty {
                Text("添加分割线后，图片可以分别填充到生成的区域中。")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            } else {
                ForEach(Array(settings.dividerLines.enumerated()), id: \.element.id) { index, divider in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("分割线 \(index + 1) 角度")
                                .font(.caption2)
                                .foregroundStyle(LF.textSecondary)
                            Spacer()
                            Text(String(format: "%.0f°", divider.angle))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(LF.textSecondary)
                            Button(role: .destructive) {
                                onRemoveDivider(index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                            .accessibilityLabel("删除分割线")
                            .disabled(!dividerEditingEnabled)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(divider.angle) },
                                set: { onAngleChange(index, CGFloat($0)) }
                            ),
                            in: 0...180,
                            step: 1
                        )
                        .tint(LF.actionPrimary)
                        .disabled(!dividerEditingEnabled)
                        .frame(height: 20)
                    }
                }
            }

            let regionCount = BackgroundPartitionGeometry.regionCount(
                for: settings,
                in: canvasRect
            )
            if regionCount > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("素材覆盖区域（可多选）")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LF.textSecondary)
                    HStack(spacing: 5) {
                        ForEach(0..<regionCount, id: \.self) { partition in
                            Button {
                                onPartitionSelect(partition)
                            } label: {
                                Text("区域 \(partition + 1)")
                                    .font(.caption2.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(settings.resolvedAssignedPartitions.contains(partition)
                                ? LF.selectionText
                                : LF.textPrimary)
                            .background(
                                settings.resolvedAssignedPartitions.contains(partition)
                                    ? LF.selectionFill
                                    : LF.surface2,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke(
                                        settings.resolvedAssignedPartitions.contains(partition)
                                            ? LF.selectionStroke
                                            : LF.header.opacity(0.24),
                                        lineWidth: settings.resolvedAssignedPartitions.contains(partition) ? 1.5 : 1
                                    )
                            }
                        }
                    }
                }
            }

            if !settings.dividerLines.isEmpty {
                Text("当前分区：\(regionCount)")
                    .font(.caption2)
                    .foregroundStyle(LF.textSecondary)
            }
        }
        .padding(10)
        .background(LF.surface2.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CollageLayerOption: Identifiable {
    let id: UUID
    let title: String
    let index: Int
    let isSelected: Bool
}

private struct CollageSourceChip: View {
    let item: BackgroundMediaItem
    let assignedPartitions: [Int]
    let layerIndex: Int
    let layerOptions: [CollageLayerOption]
    let isSelected: Bool
    let canDuplicate: Bool
    let onSelect: () -> Void
    let onSelectLayer: (UUID) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onSelect) {
                VStack(spacing: 5) {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = BackgroundStore.shared.loadFrame(named: item.id, at: 0) {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                LF.surface2
                            }
                        }
                        .frame(width: 84, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white, LF.actionPrimary)
                                .padding(4)
                        }
                    }
                    Text(item.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .frame(width: 84)
                    if assignedPartitions.isEmpty {
                        Text("未分配")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(LF.textSecondary)
                    } else {
                        Text(assignedPartitions.map { "区\($0 + 1)" }.joined(separator: " · "))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(LF.selectionText)
                            .lineLimit(1)
                            .frame(width: 84)
                    }
                }
                .padding(.top, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LF.textPrimary)

            HStack(spacing: 1) {
                Menu {
                    ForEach(layerOptions) { option in
                        Button {
                            onSelectLayer(option.id)
                        } label: {
                            HStack {
                                Text(option.title)
                                if option.isSelected {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text("\(layerIndex)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .frame(width: 22, height: 22)
                        .background(LF.selectionFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LF.selectionText)
                .accessibilityLabel("选择图层")

                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(layerIndex == 1)
                .accessibilityLabel("上移图层")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(layerIndex == layerOptions.count)
                .accessibilityLabel("下移图层")

                Button(action: onDuplicate) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!canDuplicate)
                .accessibilityLabel("创建此素材的独立实例")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("删除拼接素材")
            }
            .foregroundStyle(LF.textSecondary)
        }
        .padding(5)
        .frame(width: 112)
        .background(isSelected ? LF.selectionFill : LF.surface2.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isSelected ? LF.selectionStroke : LF.header.opacity(0.18), lineWidth: isSelected ? 1.5 : 1)
        }
    }
}
