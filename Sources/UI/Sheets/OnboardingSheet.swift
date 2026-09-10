import SwiftUI

/// First-run welcome flow. Three screens (welcome → AI → scrobbling)
/// each explaining an opt-in surface so new users know what the app
/// does and doesn't do before they poke around.
///
/// Presentation contract:
///   - Shown once, ever. Completion is persisted under
///     `onboarding.hasCompleted` in UserDefaults; the sheet itself
///     is a plain `.sheet(isPresented:)` driven by
///     `AppEnvironment.shouldShowOnboarding`.
///   - Dismissible at any point via the top-right ✕ or by
///     completing the flow. Dismissal marks it complete either way
///     — a user who taps ✕ has seen "there IS an app here" and
///     re-showing the tour on next launch would feel pushy.
///   - Zero blocking: nothing on the app is gated behind
///     completing onboarding. Anonymous playback works
///     immediately, AI + scrobbling remain opt-in via Settings.
struct OnboardingSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var pageIndex: Int = 0
    /// Local sign-in presentation. OnboardingSheet shows SignInView
    /// as its OWN nested sheet instead of toggling
    /// `env.isSignInSheetPresented`, because that flag's owning view
    /// (RootView) sits underneath this sheet and cannot present a
    /// second one while this one is up.
    @State private var showSignIn: Bool = false
    private static let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    complete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Text.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss onboarding")
                .padding(14)
            }
            Spacer(minLength: 12)
            TabView(selection: $pageIndex) {
                welcomePage.tag(0)
                signInPage.tag(1)
                aiPage.tag(2)
                scrobblingPage.tag(3)
            }
            .tabViewStyle(.automatic)
            .frame(minHeight: 320)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ForEach(0..<Self.pageCount, id: \.self) { i in
                    Circle()
                        .fill(i == pageIndex ? Theme.red : Theme.Fill.strong)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 12)
            HStack {
                if pageIndex > 0 {
                    Button("Back") { pageIndex -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button {
                    if pageIndex < Self.pageCount - 1 {
                        pageIndex += 1
                    } else {
                        complete()
                    }
                } label: {
                    Text(pageIndex < Self.pageCount - 1 ? "Next" : "Get started")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 520, height: 520)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSignIn) {
            SignInView()
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        pageLayout(
            icon: "waveform",
            title: "Welcome to Riff",
            body: [
                "A native macOS client for YouTube Music. Works anonymously by default — no account required to browse or play music.",
                "Sign in with your Google account to remove ads (if you have YouTube Music Premium) and unlock your Liked Songs, playlists, and subscriptions. Open from the account button (top-right) any time.",
            ]
        )
    }

    /// The one page that carries a real call-to-action. Everything
    /// else in onboarding is informational; this is where the user
    /// actually does the thing that removes ads + syncs their
    /// library. Reflects live sign-in state so a user who signs in
    /// here sees confirmation without leaving the flow.
    private var signInPage: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Theme.red.opacity(0.15))
                    .frame(width: 88, height: 88)
                Image(systemName: env.isSignedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(env.isSignedIn ? .green : Theme.red)
            }
            Text(env.isSignedIn ? "You're signed in" : "Sign in with Google")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 12) {
                if env.isSignedIn {
                    Text("Your Liked Songs, playlists, and subscriptions are loading into the Library tab.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                } else {
                    labeledBenefit("nosign", "No ads", "If your Google account has YouTube Music Premium, playback is ad-free.")
                    labeledBenefit("heart.text.square", "Your library", "Liked Songs, playlists, and podcast subscriptions sync in.")
                    labeledBenefit("lock.shield", "Stays on your Mac", "Riff has no account system — the sign-in cookie lives only in your local keychain, never sent anywhere but Google.")
                }
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 24)

            if !env.isSignedIn {
                Button {
                    showSignIn = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                        Text("Sign in with Google")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Theme.red)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Google sign-in in a secure window.")
            }
        }
        .padding(.horizontal, 8)
    }

    private func labeledBenefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon == "nosign" ? "nosign" : icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.red)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aiPage: some View {
        pageLayout(
            icon: "sparkles",
            title: "AI features (optional)",
            body: [
                "Riff can build queues from a vibe (\u{201C}rainy Sunday indie folk\u{201D}), translate lyrics, and show context cards about the current track.",
                "Bring your own API key from Anthropic, Groq (free tier), or Ollama (fully local). Riff never proxies — requests go straight from your Mac to the provider.",
                "Set it up in Settings → AI features.",
            ]
        )
    }

    private var scrobblingPage: some View {
        pageLayout(
            icon: "chart.xyaxis.line",
            title: "Scrobbling (optional)",
            body: [
                "Track everything you play at Last.fm or ListenBrainz. Both are opt-in and free.",
                "Riff uses the standard scrobble rule: half the track or 4 minutes, whichever comes first.",
                "Paste your credentials in Settings → Scrobbling to turn it on.",
            ]
        )
    }

    private func pageLayout(icon: String, title: String, body: [String]) -> some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Theme.red.opacity(0.15))
                    .frame(width: 88, height: 88)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Theme.red)
            }
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(body, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 24)
        }
        .padding(.horizontal, 8)
    }

    private func complete() {
        env.markOnboardingComplete()
        dismiss()
    }
}
