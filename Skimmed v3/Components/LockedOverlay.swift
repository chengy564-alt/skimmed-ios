import SwiftUI

/// Blurs its content (real native `.blur`) and overlays a small glass lock
/// chip. Content is non-interactive and hidden from accessibility while locked.
///
/// Animate `isLocked` to `false` to play the unlock: the lock pops open and
/// the chip fades away, the blur dissolves, and a diagonal light sweep passes
/// across the card. `unlockDelay` staggers the sequence so sibling cards can
/// cascade.
struct Locked<Content: View>: View {
    var label: String = "Unlock to view"
    var isLocked: Bool = true
    var unlockDelay: Double = 0
    let content: Content

    @State private var sweeping = false

    init(
        label: String = "Unlock to view",
        isLocked: Bool = true,
        unlockDelay: Double = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.isLocked = isLocked
        self.unlockDelay = unlockDelay
        self.content = content()
    }

    var body: some View {
        content
            .blur(radius: isLocked ? 7 : 0)
            .allowsHitTesting(!isLocked)
            .accessibilityHidden(isLocked)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                if sweeping {
                    LightSweep()
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isLocked {
                    lockChip
                        .transition(
                            .scale(scale: 1.25).combined(with: .opacity)
                        )
                }
            }
            .animation(.easeOut(duration: 0.65).delay(unlockDelay), value: isLocked)
            .onChange(of: isLocked) { _, locked in
                guard !locked else { return }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64((unlockDelay + 0.1) * 1_000_000_000))
                    sweeping = true
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    sweeping = false
                }
            }
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: isLocked)
    }

    private var lockChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.app(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(.app(12, weight: .semibold))
                .foregroundStyle(Theme.cream.opacity(0.9))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: Capsule())
    }
}
