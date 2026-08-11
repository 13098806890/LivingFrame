import LivingFrameCore
import SwiftUI

/// 画布比例选择器（修改比例时元素位置按比例换算）
struct AspectPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ForEach(CanvasAspect.allCases) { aspect in
                    let current = isCurrent(aspect)
                    Button {
                        appState.setCanvasAspect(aspect)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait")
                                .rotationEffect(.degrees(aspect == .landscape16x9 ? 90 : 0))
                                .foregroundStyle(current ? LF.gold : LF.textSecondary)
                            Text(aspect.title)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            if current {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(LF.gold)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(LF.surface2, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(LF.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                Text("修改比例会等比换算已有素材的位置与大小")
                    .font(.caption)
                    .foregroundStyle(LF.textSecondary)
                Spacer()
            }
            .padding()
            .navigationTitle("画布比例")
            .navigationBarTitleDisplayMode(.inline)
            .magicBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func isCurrent(_ aspect: CanvasAspect) -> Bool {
        guard let comp = appState.composition else { return false }
        return CanvasAspect.aspect(for: comp.canvasRect.size) == aspect
    }
}
