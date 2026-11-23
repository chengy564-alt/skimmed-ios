import SwiftUI

/// Six-detent Liquid-Glass slider for onboarding Q1 (trip frequency).
///
/// Driven directly off `TripFreqBucket.allCases`, so the detent index and the
/// bound bucket stay 1:1. The glass thumb follows the finger continuously
/// while dragging — no mid-drag jumping — with the amber fill trailing it live;
/// on release it springs to the nearest detent. There is **no** value bubble on
/// the thumb. Under the track each stop shows its short glyph (1 2 3 4 10+ and
/// an airplane), and the active stop brightens to `Theme.cream` and scales up.
/// Below the whole control a single caption line cross-dissolves to the active
/// selection's `.caption`. `selection` stays nil until first touch so the
/// caller's "answered?" logic keeps working.
struct DetentSlider: View {
    @Binding var selection: TripFreqBucket?

    private let buckets = TripFreqBucket.allCases

    /// Finger-tracked thumb x while dragging; nil at rest (thumb sits on the
    /// selected detent).
    @State private var dragX: CGFloat? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let trackHeight: CGFloat = 12
    private let thumbSize: CGFloat = 30
    private let labelRowHeight: CGFloat = 20

    private var selectedIndex: Int? {
        selection.flatMap { buckets.firstIndex(of: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            slider
            caption
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    // MARK: - Track + thumb + detent labels

    private var slider: some View {
        GeometryReader { geo in
            let usable = geo.size.width - thumbSize
            let step = usable / CGFloat(max(1, buckets.count - 1))
            let restX = CGFloat(selectedIndex ?? 0) * step
            let thumbX = dragX ?? restX

            VStack(alignment: .leading, spacing: 12) {
                track(thumbX: thumbX, step: step, usable: usable)
                    .frame(height: thumbSize)
                labelRow(step: step)
                    .frame(height: labelRowHeight)
            }
        }
        .frame(height: thumbSize + 12 + labelRowHeight)
    }

    private func track(thumbX: CGFloat, step: CGFloat, usable: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Glass track.
            Capsule()
                .fill(Color.white.opacity(0.04))
                .frame(height: trackHeight)
                .glass(in: Capsule())

            // Amber fill trails the thumb live — only once something is picked.
            if selection != nil {
                Capsule()
                    .fill(Theme.buttonGradient)
                    .frame(width: thumbX + thumbSize, height: trackHeight)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 2)
            }

            // Detent ticks — pop subtly as the thumb passes over them.
            HStack(spacing: 0) {
                ForEach(buckets.indices, id: \.self) { i in
                    let near = abs(thumbX - CGFloat(i) * step) < step * 0.3
                    Circle()
                        .fill(tickColor(i))
                        .frame(width: 4, height: 4)
                        .scaleEffect(near && dragX != nil && !reduceMotion ? 1.9 : 1)
                        .animation(
                            .spring(response: 0.25, dampingFraction: 0.6),
                            value: near && dragX != nil
                        )
                    if i != buckets.count - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, (thumbSize - 4) / 2)

            // Glass thumb — follows the finger exactly while dragging.
            Circle()
                .fill(selection == nil ? Theme.surface3 : Theme.accentHot)
                .frame(width: thumbSize, height: thumbSize)
                .glass(in: Circle())
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(selection == nil ? 0.18 : 0.4),
                        lineWidth: 1
                    )
                )
                .scaleEffect(dragX != nil && !reduceMotion ? 1.15 : 1)
                .offset(x: thumbX)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                    value: dragX != nil
                )
        }
        .frame(height: thumbSize)
        .contentShape(Rectangle())
        .gesture(drag(usable: usable, step: step))
    }

    /// Short glyphs under each detent — the active one brightens and pops.
    private func labelRow(step: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(buckets.indices, id: \.self) { i in
                detentLabel(i)
                    .frame(width: thumbSize)
                    .offset(x: CGFloat(i) * step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detentLabel(_ i: Int) -> some View {
        let bucket = buckets[i]
        let isActive = i == selectedIndex

        Group {
            if bucket == .airports {
                Image(systemName: "airplane")
                    .font(.system(size: 11, weight: .semibold))
            } else {
                Text(bucket.displayLabel)
                    .font(.app(11, weight: .semibold))
            }
        }
        .foregroundStyle(isActive ? Theme.cream : Theme.muted.opacity(0.7))
        .scaleEffect(isActive && !reduceMotion ? 1.15 : 1)
        .animation(
            reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.7),
            value: isActive
        )
    }

    // MARK: - Caption (cross-dissolves, never attached to the thumb)

    private var caption: some View {
        ZStack(alignment: .leading) {
            if let selection {
                Text(selection.caption)
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Theme.cream.opacity(0.92))
                    .id(selection)
                    .transition(.opacity)
            } else {
                Text("Drag to set how often you travel")
                    .font(.app(12.5))
                    .foregroundStyle(Theme.muted)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: selection)
    }

    // MARK: - Gesture

    private func drag(usable: CGFloat, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let x = min(max(0, value.location.x - thumbSize / 2), usable)
                let nearest = buckets[Int((x / step).rounded())]
                if reduceMotion {
                    // Snap without continuous follow — thumb sits on detents.
                    if nearest != selection { selection = nearest }
                } else {
                    dragX = x
                    if nearest != selection {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            selection = nearest
                        }
                    }
                }
            }
            .onEnded { value in
                if reduceMotion {
                    let x = min(max(0, value.location.x - thumbSize / 2), usable)
                    selection = buckets[Int((x / step).rounded())]
                    dragX = nil
                } else {
                    // Spring home to the nearest detent.
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                        dragX = nil
                    }
                }
            }
    }

    private func tickColor(_ i: Int) -> Color {
        guard let selectedIndex else { return Color.white.opacity(0.25) }
        return i <= selectedIndex ? Theme.onAccent.opacity(0.55) : Color.white.opacity(0.25)
    }
}
