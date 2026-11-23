import SwiftUI

/// Selectable pill chip — the `.chip` recipe. Selected: amber-tinted fill,
/// amber border + text, with a springy pop; unselected: opaque surface,
/// faint white border. Presses scale down via the shared PressStyle.
struct Chip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.app(13, weight: .semibold))
                .foregroundStyle(isOn ? Theme.accent : Theme.cream)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    isOn ? Theme.accent.opacity(0.15) : Theme.surface,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isOn ? Theme.accent : Color.white.opacity(0.1),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .scaleEffect(isOn ? 1.04 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: isOn)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}
