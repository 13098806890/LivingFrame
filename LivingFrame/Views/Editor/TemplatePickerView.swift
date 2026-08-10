import LivingFrameCore
import SwiftUI

/// 内置模板选择：实时渲染缩略图
struct TemplatePickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let templates = TemplateCatalog.shared.templates

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(templates) { template in
                        templateCard(template)
                    }
                }
                .padding()
            }
            .navigationTitle("内置模板")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(LF.gold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func templateCard(_ template: MagicTemplate) -> some View {
        Button {
            appState.applyTemplate(template)
            dismiss()
        } label: {
            VStack(spacing: 8) {
                TemplateThumbnail(template: template)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(LF.surface2, lineWidth: 1)
                    }
                VStack(spacing: 2) {
                    Text(template.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LF.textPrimary)
                    Text(template.tagline)
                        .font(.caption2)
                        .foregroundStyle(LF.textSecondary)
                        .lineLimit(1)
                }
                Label("内置 · 离线可用", systemImage: "internaldrive")
                    .font(.caption2)
                    .foregroundStyle(LF.gold)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 模板实时预览（用真实装饰渲染缩略图）
struct TemplateThumbnail: View {
    let template: MagicTemplate

    var body: some View {
        if let image = TemplatePreviewRenderer.render(template) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Color.black
        }
    }
}

/// 模板缩略图渲染器（独立于 CompositionRenderer 的轻量管线）
enum TemplatePreviewRenderer {
    static func render(_ template: MagicTemplate) -> CGImage? {
        let canvas = template.canvasPreset ?? CanvasSpec(width: 400, height: 533)
        let composition = Composition(
            name: template.name,
            canvas: canvas,
            duration: 1,
            background: template.background ?? .dark
        )
        var elements: [CompositionElement] = []
        for decoration in template.decorations {
            elements.append(CompositionElement(
                kind: .decoration(decorationID: decoration.decorationID),
                name: decoration.decorationID,
                transform: decoration.transform,
                zIndex: decoration.zIndex
            ))
        }
        for effectID in template.effectPresets {
            elements.append(CompositionElement(
                kind: .effect(effectID: effectID),
                name: effectID,
                transform: ElementTransform(
                    position: CGPoint(x: canvas.width / 2, y: canvas.height / 2),
                    scale: 1, rotation: 0
                ),
                zIndex: 60
            ))
        }
        var comp = composition
        comp.elements = elements
        return CompositionRenderer().render(comp, at: 0)
    }
}
