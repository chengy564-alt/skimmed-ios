import Combine
import CoreMotion
import SwiftUI

/// MotionManager — a tiny gyroscope tap that lets on-screen surfaces catch the
/// light as you tilt the phone. Wraps CoreMotion's device-motion stream and
/// publishes a SMOOTHED, clamped, normalized roll/pitch (−1…1) that views map
/// straight into a `rotation3DEffect`.
///
/// The raw attitude stream is jittery, so every sample is run through a
/// low-pass filter before publishing; the result is buttery, never twitchy.
/// CoreMotion returns nothing in the Simulator (no gyro), so we guard
/// `isDeviceMotionAvailable` and simply stay flat (0, 0) — no crash, no motion.
@MainActor
final class MotionManager: ObservableObject {
    static let shared = MotionManager()

    /// Left/right tilt, normalized to −1…1 (right positive). Flat when idle.
    @Published private(set) var roll: Double = 0
    /// Forward/back tilt, normalized to −1…1 (toward you positive). Flat idle.
    @Published private(set) var pitch: Double = 0

    private let motion = CMMotionManager()

    /// Smoothing weight for the low-pass filter (0 = frozen, 1 = raw). Small so
    /// the surface glides toward the new angle instead of snapping.
    private let smoothing = 0.12
    /// The tilt range we care about, in radians (~28°). Beyond this we clamp, so
    /// a small wrist roll already reaches full deflection — subtle but alive.
    private let range = 0.5

    /// Reference count so overlapping `onAppear`/`onDisappear` (e.g. during a
    /// tab swap) don't tear the stream down while a view still wants it.
    private var subscribers = 0

    private init() {}

    func start() {
        subscribers += 1
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }

        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let attitude = data?.attitude else { return }

            let targetRoll = self.normalize(attitude.roll)
            let targetPitch = self.normalize(attitude.pitch)

            // Low-pass: ease the published value toward the fresh sample.
            self.roll += (targetRoll - self.roll) * self.smoothing
            self.pitch += (targetPitch - self.pitch) * self.smoothing
        }
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        motion.stopDeviceMotionUpdates()
        // Settle back to flat so a later re-appear doesn't start mid-tilt.
        roll = 0
        pitch = 0
    }

    /// Clamp to ±range and scale to −1…1.
    private func normalize(_ radians: Double) -> Double {
        max(-1, min(1, radians / range))
    }
}
