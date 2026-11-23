import SwiftUI

/// Amber pill CTA — the `.btn-primary` recipe: hot-to-warm vertical gradient,
/// dark ink text, amber glow shadow, 0.4 opacity when disabled.
/// Presses scale down with a spring and fire a soft impact haptic.
struct PrimaryButton: View {
    let title: String
    var leadingIcon: String? = nil
    var trailingIcon: String? = "chevron.right"
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 8) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .font(.system(size: 14, weight: .bold))
                }
                Text(title)
                    .font(.app(16, weight: .bold))
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.buttonGradient, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    .blendMode(.overlay)
            )
            .shadow(
                color: isDisabled ? .clear : Theme.accent.opacity(0.35),
                radius: 12, x: 0, y: 8
            )
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.8), trigger: taps)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .animation(.easeOut(duration: 0.2), value: isDisabled)
    }
}
