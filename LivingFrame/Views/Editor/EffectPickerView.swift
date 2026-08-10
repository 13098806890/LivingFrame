import LivingFrameCore
import SwiftUI

/// 魔法特效选择
struct EffectPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let effects: [EffectPreset] = [
        EffectPreset(id: "glow-soft", name: NSLocalizedString("柔光", comment: "Effect name"), icon: "circle.dotted"),
        EffectPreset(id: "glow-orb", name: NSLocalizedString("光球", comment: "Effect name"), icon: "circle.fill"),
        EffectPreset(id: "dust", name: NSLocalizedString("飘尘", comment: "Effect name"), icon: "sparkles"),
        EffectPreset(id: "wand-beam", name: NSLocalizedString("魔杖光束", comment: "Effect name"), icon: "wand.and.stars"),
        EffectPreset(id: "vignette", name: NSLocalizedString("暗角", comment: "Effect name"), icon: "camera.aperture")
    ]

    var body: some View {
        NavigationStack {
            List(effects) { effect in
                Button {
                    appState.addEffect(effect.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: effect.icon)
                            .font(.title3)
                            .foregroundStyle(LF.gold)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effect.name)
                                .font(.headline)
                            Text("叠加到画布，可在时间轴上调整")
                                .font(.caption)
                                .foregroundStyle(LF.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(LF.gold)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("魔法特效")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(LF.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(LF.gold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct EffectPreset: Identifiable {
    let id: String
    let name: String
    let icon: String
}
