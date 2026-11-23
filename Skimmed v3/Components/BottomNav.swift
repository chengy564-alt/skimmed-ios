import SwiftUI

/// Floating pill nav with native Liquid Glass material; the active icon sits in a
/// solid amber circle that slides between tabs (matched geometry) with a spring,
/// and the newly selected icon bounces. All four tabs navigate; any tab
/// removed from `enabled` falls back to a bounce-in-place stub.
struct BottomNav: View {
    @Binding var current: String
    /// Tabs that actually navigate; the rest bounce in place.
    var enabled: Set<String> = ["home", "trips", "cards", "profile"]

    @State private var stubBounces: [String: Int] = [:]
    @Namespace private var indicatorNamespace

    private struct NavItem: Identifiable {
        let id: String
        let label: String
        let icon: String
    }

    private let items: [NavItem] = [
        NavItem(id: "home", label: "Home", icon: "house.fill"),
        NavItem(id: "trips", label: "Trips", icon: "airplane"),
        NavItem(id: "cards", label: "Cards", icon: "creditcard.fill"),
        NavItem(id: "profile", label: "Profile", icon: "person.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isActive = item.id == current
                Button {
                    if enabled.contains(item.id) {
                        guard current != item.id else { return }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                            current = item.id
                        }
                    } else {
                        // Stub tab: acknowledge the tap without navigating.
                        stubBounces[item.id, default: 0] += 1
                    }
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 17, weight: isActive ? .bold : .regular))
                        .foregroundStyle(isActive ? Theme.onAccent : Theme.muted)
                        .symbolEffect(.bounce, value: isActive)
                        .symbolEffect(.bounce, value: stubBounces[item.id] ?? 0)
                        .frame(width: 44, height: 44)
                        .background {
                            if isActive {
                                Circle()
                                    .fill(Theme.accent)
                                    .matchedGeometryEffect(id: "activeTab", in: indicatorNamespace)
                                    .shadow(color: Theme.accent.opacity(0.45), radius: 7, x: 0, y: 4)
                            }
                        }
                        // Each tab's hit zone fills its full quarter of the bar
                        // (≥44pt tall) — not just the 44pt icon circle — so the
                        // whole slot registers taps on device.
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .accessibilityLabel(item.label)
            }
        }
        .sensoryFeedback(.selection, trigger: current)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: stubBounces)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glass(in: Capsule())
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
    }
}
