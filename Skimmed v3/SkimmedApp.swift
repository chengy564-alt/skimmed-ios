import SwiftUI

/// Skimmed — reveals how much money a traveler has lost to hidden FX markups
/// and DCC traps, then helps them stop the leak.
///
/// App entry point. Flow between screens is simple local view state, exactly
/// like the Next.js prototype's route transitions:
/// onboarding (4 screens) → reveal (paywall) → home.
@main
struct SkimmedApp: App {

    @Environment(\.scenePhase) private var scenePhase

    private enum Screen {
        case onboarding, reveal, home
    }

    /// Set once the user finishes onboarding (reaches Home). Persisted, so a
    /// returning user who has already onboarded goes STRAIGHT to Home on every
    /// cold launch — onboarding never shows again after it's completed.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @State private var screen: Screen
    /// Cold-launch splash — created once per process start, so returning
    /// from background never replays it.
    @State private var showSplash = true

    init() {
        // Route straight to Home for returning users; first-run starts at
        // onboarding. Read the flag directly since @AppStorage isn't available
        // yet inside init.
        let onboarded = UserDefaults.standard.bool(forKey: "hasOnboarded")
        _screen = State(initialValue: onboarded ? .home : .onboarding)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackdrop()

                switch screen {
                case .onboarding:
                    OnboardingView(
                        onFinished: {
                            withAnimation(.easeInOut(duration: 0.35)) { screen = .reveal }
                        },
                        onSkipped: {
                            // Nothing imported — nothing to reveal. Straight
                            // to Home's empty state.
                            withAnimation(.easeInOut(duration: 0.35)) { screen = .home }
                            hasOnboarded = true
                        }
                    )
                    .transition(.opacity)
                case .reveal:
                    RevealView {
                        withAnimation(.easeInOut(duration: 0.35)) { screen = .home }
                        hasOnboarded = true
                    }
                    .transition(.opacity)
                case .home:
                    MainTabs()
                        .transition(.opacity)
                }
            }
            .overlay {
                if showSplash {
                    LaunchSplashView {
                        showSplash = false
                    }
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .task {
                await AppStore.shared.refreshProvisionalRates()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await AppStore.shared.refreshProvisionalRates() }
            }
        }
    }
}

/// Post-subscribe tab shell: hosts the floating BottomNav above whichever
/// tab is active — Home, Trips, Cards, and Profile all navigate.
private struct MainTabs: View {
    @State private var tab = "home"
    /// Set by Home's leak map; TripsView consumes it and opens the matching
    /// trip's audit/detail.
    @State private var pendingTripCountry: String? = nil

    /// Trip Mode master switch — owned here so the calm-night wash can cover
    /// the whole Home page, not just elements inside HomeView.
    @State private var tripLive = true

    var body: some View {
        ZStack(alignment: .bottom) {
            // Calm night: when Trip Mode is off on Home, the amber backdrop cools
            // to a moonlit blue-grey.
            LinearGradient(
                colors: [
                    Color(hex: "#0D141D").opacity(0.88),
                    Color(hex: "#0A0E14").opacity(0.94),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .opacity(tab == "home" && !tripLive ? 1 : 0)
            .animation(.easeInOut(duration: 0.6), value: tripLive)
            .animation(.easeInOut(duration: 0.35), value: tab)
            .allowsHitTesting(false)

            Group {
                switch tab {
                case "cards":
                    CardsView()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 12)),
                            removal: .opacity
                        ))
                case "trips":
                    TripsView(pendingCountry: $pendingTripCountry)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 12)),
                            removal: .opacity
                        ))
                case "profile":
                    ProfileView()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 12)),
                            removal: .opacity
                        ))
                default:
                    HomeView(
                        tripLive: $tripLive,
                        onViewAllTrips: {
                            withAnimation(.easeInOut(duration: 0.35)) { tab = "trips" }
                        },
                        onOpenTripCountry: { country in
                            pendingTripCountry = country
                            withAnimation(.easeInOut(duration: 0.35)) { tab = "trips" }
                        }
                    )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 12)),
                            removal: .opacity
                        ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            BottomNav(current: $tab)
                .padding(.bottom, 8)
        }
    }
}
