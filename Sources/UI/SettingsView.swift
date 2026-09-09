import SwiftUI
import AppKit

/// User-facing OAuth credential setup. Shown when:
/// 1. The user explicitly opens it from the menu bar / account menu, or
/// 2. They tap a Library section while signed in with default credentials
///    (which can't reach Data API v3).
///
/// The default `client_id` we ship is the public YouTube TV one, which
/// works for sign-in but its GCP project doesn't have Data API v3
/// enabled — so Library calls 403. Pasting their own credentials here
/// fixes that.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var clientId: String = ""
    @State private var clientSecret: String = ""
    @State private var saved = false

    // MARK: - AI features state
    /// Buffer for the Anthropic API key. We load whatever is in
    /// Keychain on appear; the buffer is what the user is editing
    /// before they hit Save. Never logged, never persisted outside
    /// Keychain.
    @State private var anthropicAPIKey: String = ""
    @State private var anthropicModel: String = AnthropicProvider.defaultModel
    @State private var aiSaveStatus: String? = nil
    @State private var aiTestResult: TestResult? = nil
    @State private var aiTestInFlight: Bool = false

    // Groq + Ollama buffers. Loaded on appear; cleared after Save.
    @State private var activeProvider: LLMProviderKind = .anthropic
    @State private var groqAPIKey: String = ""
    @State private var groqModel: String = GroqProvider.defaultModel
    @State private var ollamaBaseURL: String = OllamaProvider.defaultBaseURL.absoluteString
    @State private var ollamaModel: String = OllamaProvider.defaultModel

    /// Buffer for the lyrics-translation language picker. The picker
    /// selection lives on `env.translationLanguage` (persisted); this
    /// `@State` is the visual selection of the segmented control — we
    /// route "Other..." through `customLanguageBuffer` so the user can
    /// type in a language not in the preset list. Sentinel that flags
    /// the picker as in "Other" mode. Distinct from any real language
    /// name we'd render, so a user typing "Other" as a real language
    /// is impossible — but it's just a UI sentinel.
    @State private var customLanguageBuffer: String = ""
    private static let otherLanguageSentinel = "Other…"

    // MARK: - Scrobbling state (D1)

    /// Editable buffers for the scrobbling credential fields. Loaded
    /// from Keychain on appear (presence-only; we never re-render the
    /// raw secret back into the SecureField). On Save we push the
    /// trimmed values back and clear the buffer.
    @State private var lastFmUsernameBuffer: String = ""
    @State private var lastFmAPIKeyBuffer: String = ""
    @State private var lastFmAPISecretBuffer: String = ""
    @State private var lastFmSessionKeyBuffer: String = ""
    @State private var lastFmEnabled: Bool = false
    @State private var lastFmStatus: String? = nil

    @State private var listenBrainzTokenBuffer: String = ""
    @State private var listenBrainzEnabled: Bool = false
    @State private var listenBrainzUsername: String? = nil
    @State private var listenBrainzStatus: String? = nil
    @State private var listenBrainzTestInFlight: Bool = false

    @State private var diagnosticsExporting: Bool = false
    @State private var diagnosticsStatus: String? = nil

    /// Confirms "Clear all overrides" — action is destructive and
    /// affects every locally-edited track title/artist/album.
    @State private var confirmClearOverrides: Bool = false

    // Cookie-import (advanced sign-in) state.
    @State private var showCookieImport: Bool = false
    @State private var cookiePasteBuffer: String = ""
    @State private var cookieImportStatus: String? = nil

    enum TestResult: Equatable {
        case success
        case failure(String)
    }
    /// Email of the signed-in Google account, when we can fetch it
    /// (Device-Flow path only — see UserInfoService for the rationale).
    /// Nil while loading or for cookie-based sessions.
    @State private var accountEmail: String? = nil
    /// Account name + handle from InnerTube account_menu — the source
    /// that works for cookie-import sessions (accountEmail only
    /// populates for OAuth Device-Flow sign-ins).
    @State private var accountName: String? = nil
    @State private var accountHandle: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    accountSection
                    Divider().background(Theme.divider)
                    keyboardShortcutsSection
                    Divider().background(Theme.divider)
                    playbackSection
                    Divider().background(Theme.divider)
                    scrobblingSection
                    Divider().background(Theme.divider)
                    interfaceSection
                    Divider().background(Theme.divider)
                    libraryAccessSection
                    Divider().background(Theme.divider)
                    aiFeaturesSection
                    if !env.blockedArtistIds.isEmpty {
                        Divider().background(Theme.divider)
                        blockedArtistsSection
                    }
                    if !env.trackOverrides.sortedVideoIds.isEmpty {
                        Divider().background(Theme.divider)
                        trackOverridesSection
                    }
                    Divider().background(Theme.divider)
                    diagnosticsSection
                    Divider().background(Theme.divider)
                    aboutSection
                }
                .padding(28)
            }
        }
        .frame(minWidth: 540, minHeight: 620)
        .onAppear {
            let config = OAuthClientConfig.load()
            if config.isCustom {
                clientId = config.clientId
                clientSecret = config.clientSecret
            }
            // Load AI features state from Keychain. Show a masked
            // placeholder if a key is already saved — never echo the
            // raw key back into the SecureField, even though SwiftUI
            // would render it as dots.
            if AnthropicProvider.storedAPIKey() != nil {
                anthropicAPIKey = "" // empty buffer; placeholder hints "already saved"
            }
            anthropicModel = AnthropicProvider.storedModel()
            // AI backend + per-provider settings — mirror stored
            // state into the on-screen buffers. Secrets stay empty
            // (never echo a saved key back into the SecureField).
            activeProvider = LLMProviderKind.active
            groqModel = GroqProvider.storedModel()
            ollamaBaseURL = OllamaProvider.storedBaseURL().absoluteString
            ollamaModel = OllamaProvider.storedModel()
            // Scrobbling: load enabled toggles + cached usernames so
            // the section renders the user's existing state. Secrets
            // stay in Keychain; buffers stay empty (we never echo a
            // stored secret back into the SecureField).
            lastFmEnabled = UserDefaults.standard.bool(forKey: ScrobblerDefaults.lastFmEnabled)
            if let stored = LastFmScrobbler.storedCredentials() {
                lastFmUsernameBuffer = stored.username
            }
            listenBrainzEnabled = UserDefaults.standard.bool(forKey: ScrobblerDefaults.listenBrainzEnabled)
            listenBrainzUsername = UserDefaults.standard.string(forKey: ScrobblerDefaults.listenBrainzUsername)
        }
        .task {
            // Best-effort fetch on open; fails silently when the user
            // came in via cookie-only sign-in (no bearer to call
            // userinfo with). Cached so reopening Settings doesn't
            // re-hit the network.
            if env.isSignedIn {
                // account_menu (works for cookie sessions) first;
                // OAuth email as a supplement for Device-Flow.
                let info = await env.innerTube.fetchAccountInfo()
                accountName = info?.name
                accountHandle = info?.handle
                // No account header while "signed in" is the dead-session
                // fingerprint — let the liveness probe flip the state
                // rather than showing a generic "Signed in" line.
                if info == nil { env.probeSessionLiveness(force: true) }
                accountEmail = await UserInfoService.emailIfAvailable()
            }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Account")
            HStack(spacing: 14) {
                Circle()
                    .fill(env.isSignedIn ? Theme.red : Color.white.opacity(0.1))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: env.isSignedIn ? "person.fill" : "person")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    // Prefer the real account display name (works for
                    // cookie sessions via account_menu); fall back to
                    // the generic line.
                    Text(env.isSignedIn ? (accountName ?? "Signed in to YouTube Music") : "Not signed in")
                        .font(.system(size: 13, weight: .semibold))
                    if env.isSignedIn, let handle = accountHandle ?? accountEmail {
                        // Channel handle (@name) from account_menu, or
                        // the OAuth email when that path was used.
                        Text(handle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .textSelection(.enabled)
                    }
                    Text(env.isSignedIn
                         ? "Library + personalized recommendations are available."
                         : "Anonymous browse + click-to-play work; sign in for Library access.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                if env.isSignedIn {
                    Button("Sign Out") {
                        UserInfoService.cachedEmail = nil
                        env.signOut()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Sign In…") {
                        env.isSignInSheetPresented = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.red)
                }
            }

            // Cookie import — the free-account / passkey-friendly
            // path. Only offered when signed out (no point pasting a
            // session over a live one). See CookieJar.importPastedCookies.
            if !env.isSignedIn {
                cookieImportBlock
            }
        }
    }

    @ViewBuilder
    private var cookieImportBlock: some View {
        DisclosureGroup(isExpanded: $showCookieImport) {
            VStack(alignment: .leading, spacing: 10) {
                stepRow(n: 1, title: "Sign in to music.youtube.com in your normal browser (Safari/Chrome). Passkeys, password managers, and 2FA all work there.") { EmptyView() }
                stepRow(n: 2, title: "Open developer tools (⌥⌘I) on that tab, go to the Console, and run this one-liner:") {
                    HStack(spacing: 8) {
                        Text("document.cookie")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .textSelection(.enabled)
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString("document.cookie", forType: .string)
                            cookieImportStatus = "Copied — paste into the browser console."
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.red)
                        .help("Copy the console command")
                    }
                }
                stepRow(n: 3, title: "Copy the whole NAME=VALUE; … line it prints, paste it below, and hit Import. (SAPISID is included — that's the one that matters.)") { EmptyView() }

                TextEditor(text: $cookiePasteBuffer)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 72)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))

                HStack {
                    Button("Import cookies") { importCookies() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.red)
                        .disabled(cookiePasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if let status = cookieImportStatus {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(status.hasPrefix("Imported") ? .green : .orange)
                            .lineLimit(2)
                    }
                }
                Text("Riff never sees your password — only the resulting session cookie, stored in your local keychain. This is the recommended path if passkey / 2FA won't complete in the in-app window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            Text("Sign in by pasting browser cookies (advanced)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private func importCookies() {
        let raw = cookiePasteBuffer
        Task {
            let result = await CookieJar.importPastedCookies(raw)
            await MainActor.run {
                switch result {
                case .success(let count):
                    env.refreshSignedInState()
                    cookiePasteBuffer = ""
                    if env.isSignedIn {
                        cookieImportStatus = "Imported \(count) cookies — signed in."
                        env.showToast("Signed in via cookie import.")
                        dismiss()
                    } else {
                        cookieImportStatus = "Imported, but session didn't validate. Re-copy from a fresh login."
                    }
                case .missingAuthCookie:
                    cookieImportStatus = "No SAPISID cookie found — make sure you copied it."
                case .empty:
                    cookieImportStatus = "Couldn't parse any cookies from that text."
                }
            }
        }
    }

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Keyboard shortcuts")
            shortcutRow("Play / Pause",    keys: "Space")
            shortcutRow("Next track",      keys: "⌘ →")
            shortcutRow("Previous track",  keys: "⌘ ←")
            shortcutRow("Skip +30s",       keys: "⌥ ⌘ →")
            shortcutRow("Skip −15s",       keys: "⌥ ⌘ ←")
            shortcutRow("Volume up",       keys: "⌘ ↑")
            shortcutRow("Volume down",     keys: "⌘ ↓")
            shortcutRow("Toggle like",     keys: "⌘ L")
            shortcutRow("Toggle shuffle",  keys: "⇧ ⌘ S")
            shortcutRow("Cycle repeat",    keys: "⇧ ⌘ R")
            shortcutRow("Switch tabs",     keys: "⌘ 1 / 2 / 3 / 4")
            shortcutRow("Command palette", keys: "⌘ K")
            shortcutRow("Focus search",    keys: "⌘ F")
            shortcutRow("Mini Player",     keys: "⌥ ⌘ M")
            shortcutRow("Open Stats",      keys: "⇧ ⌘ Y")
            shortcutRow("Sign in",         keys: "⇧ ⌘ L")
            shortcutRow("Settings",        keys: "⌘ ,")
            shortcutRow("Close player",    keys: "⎋")
            shortcutRow("Quit",            keys: "⌘ Q")
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Playback")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Autoplay")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Keep playing similar music when your queue ends. Turn off to stop at the end of the current queue or album.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: Binding(
                    get: { env.player.autoplayEnabled },
                    set: { env.player.setAutoplayEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Track change notifications")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Show a Notification Center banner with the new track when Riff is in the background.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: Binding(
                    get: { env.trackNotificationsEnabled },
                    set: { env.trackNotificationsEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume normalization")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Smooths loudness between tracks by measuring each new track and adjusting gain toward a fixed target. Approximate — measured in-browser, not LUFS-accurate.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: Binding(
                    get: { env.player.normalizationEnabled },
                    set: { newValue in
                        Task { await env.player.setNormalizationEnabled(newValue) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Crossfade")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Fades the end of each track into the beginning of the next over the chosen duration. Volume-only — YouTube Music's audio source can't overlap two tracks, so beat-matched mixing isn't possible.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Picker("", selection: Binding(
                    get: { env.player.crossfadeSeconds },
                    set: { newValue in
                        Task { await env.player.setCrossfadeSeconds(newValue) }
                    }
                )) {
                    ForEach(PlayerBridge.crossfadePresets, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(Int(seconds))s").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
            }
        }
    }

    /// Interface preferences. Currently just the menu-bar mini player
    /// toggle; expects to grow as we add more chrome-level options
    /// (window-on-quit behavior, accent-color, dock-icon hiding).
    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Interface")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Menu bar mini player")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Show a compact playback popover next to the system clock. Click the music-note icon for transport controls and a quick way to open the floating Mini Player window.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: Binding(
                    get: { env.menuBarExtraEnabled },
                    set: { env.menuBarExtraEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    /// D1 — "Scrobbling": opt-in last.fm + ListenBrainz scrobble
    /// dispatch. Each service has its own enable toggle + credential
    /// block; flipping the toggle off stops scrobbling without
    /// clearing the credentials so the user can re-enable instantly.
    /// Credentials live in Keychain; toggles + cached display
    /// usernames live in UserDefaults.
    private var scrobblingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Scrobbling")
            Text("Send what you listen to to your last.fm or ListenBrainz profile. Both are opt-in, both stay off until you paste credentials. A track is scrobbled once you've played at least half of it, or 4 minutes — whichever comes first.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            // last.fm
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("last.fm")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { lastFmEnabled },
                        set: { newVal in
                            lastFmEnabled = newVal
                            UserDefaults.standard.set(newVal, forKey: ScrobblerDefaults.lastFmEnabled)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(LastFmScrobbler.storedCredentials() == nil)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Register an API account (link below), then run the one-off Approve flow to grant Riff scrobble permission.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = URL(string: "https://www.last.fm/api/account/create") {
                        Link("last.fm/api/account/create", destination: url)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.red.opacity(0.85))
                            .underline()
                    }
                }

                Group {
                    labeledField("Username", text: $lastFmUsernameBuffer, placeholder: "your-lastfm-name")
                    labeledSecureField("API key", text: $lastFmAPIKeyBuffer, placeholder: LastFmScrobbler.storedCredentials() == nil ? "Paste API key" : "•••• saved — paste to replace")
                    labeledSecureField("Shared secret", text: $lastFmAPISecretBuffer, placeholder: LastFmScrobbler.storedCredentials() == nil ? "Paste shared secret" : "•••• saved — paste to replace")
                    labeledSecureField("Session key", text: $lastFmSessionKeyBuffer, placeholder: LastFmScrobbler.storedCredentials() == nil ? "Paste session key" : "•••• saved — paste to replace")
                }

                Text("Get a session key by running last.fm's desktop-app auth flow once: visit last.fm/api/auth/?api_key=YOUR_KEY in a browser, click Approve, then exchange the resulting token for a session key via auth.getSession. The session key never expires.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Save credentials") { saveLastFmCredentials() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.red)
                        .disabled(!canSaveLastFm)
                    if LastFmScrobbler.storedCredentials() != nil {
                        Button("Clear") {
                            LastFmScrobbler.clearCredentials()
                            lastFmUsernameBuffer = ""
                            lastFmAPIKeyBuffer = ""
                            lastFmAPISecretBuffer = ""
                            lastFmSessionKeyBuffer = ""
                            lastFmEnabled = false
                            UserDefaults.standard.set(false, forKey: ScrobblerDefaults.lastFmEnabled)
                            lastFmStatus = "Removed."
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    if let status = lastFmStatus {
                        Text(status).font(.system(size: 12)).foregroundStyle(.green)
                    }
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // ListenBrainz
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("ListenBrainz")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if let name = listenBrainzUsername, !name.isEmpty {
                        Text("• \(name)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { listenBrainzEnabled },
                        set: { newVal in
                            listenBrainzEnabled = newVal
                            UserDefaults.standard.set(newVal, forKey: ScrobblerDefaults.listenBrainzEnabled)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(ListenBrainzScrobbler.storedToken() == nil)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grab your user-token from your ListenBrainz profile and paste it below. No additional setup needed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = URL(string: "https://listenbrainz.org/profile") {
                        Link("listenbrainz.org/profile", destination: url)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.red.opacity(0.85))
                            .underline()
                    }
                }

                labeledSecureField(
                    "User token",
                    text: $listenBrainzTokenBuffer,
                    placeholder: ListenBrainzScrobbler.storedToken() == nil
                        ? "Paste user token"
                        : "•••• saved — paste to replace"
                )

                HStack {
                    Button("Save token") { saveListenBrainzToken() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.red)
                        .disabled(listenBrainzTokenBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        testListenBrainzToken()
                    } label: {
                        if listenBrainzTestInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test connection")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(listenBrainzTestInFlight || ListenBrainzScrobbler.storedToken() == nil)
                    if ListenBrainzScrobbler.storedToken() != nil {
                        Button("Clear") {
                            ListenBrainzScrobbler.clearToken()
                            listenBrainzTokenBuffer = ""
                            listenBrainzEnabled = false
                            listenBrainzUsername = nil
                            UserDefaults.standard.set(false, forKey: ScrobblerDefaults.listenBrainzEnabled)
                            listenBrainzStatus = "Removed."
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    if let status = listenBrainzStatus {
                        Text(status).font(.system(size: 12)).foregroundStyle(.green)
                    }
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var canSaveLastFm: Bool {
        let u = lastFmUsernameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = lastFmAPIKeyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = lastFmAPISecretBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = lastFmSessionKeyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.isEmpty && !k.isEmpty && !s.isEmpty && !sk.isEmpty { return true }
        // If credentials are already saved, allow partial-update saves
        // (e.g. rotating just the API key or session key).
        return LastFmScrobbler.storedCredentials() != nil && (!u.isEmpty || !k.isEmpty || !s.isEmpty || !sk.isEmpty)
    }

    private func saveLastFmCredentials() {
        let existing = LastFmScrobbler.storedCredentials()
        let u = lastFmUsernameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = lastFmAPIKeyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = lastFmAPISecretBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = lastFmSessionKeyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        // Merge: blank fields fall back to existing stored value if any
        // (partial rotation). Final state must have all four populated.
        let finalUsername = u.isEmpty ? (existing?.username ?? "") : u
        let finalKey      = k.isEmpty ? (existing?.apiKey ?? "") : k
        let finalSecret   = s.isEmpty ? (existing?.apiSecret ?? "") : s
        let finalSession  = sk.isEmpty ? (existing?.sessionKey ?? "") : sk
        guard !finalUsername.isEmpty, !finalKey.isEmpty,
              !finalSecret.isEmpty, !finalSession.isEmpty else {
            lastFmStatus = "All four fields are required."
            return
        }
        do {
            try LastFmScrobbler.saveCredentials(
                username: finalUsername,
                apiKey: finalKey,
                apiSecret: finalSecret,
                sessionKey: finalSession
            )
            // Clear the secret buffers so they don't linger in memory.
            lastFmAPIKeyBuffer = ""
            lastFmAPISecretBuffer = ""
            lastFmSessionKeyBuffer = ""
            lastFmStatus = "Saved."
        } catch {
            lastFmStatus = "Couldn't save to Keychain."
        }
    }

    private func saveListenBrainzToken() {
        let trimmed = listenBrainzTokenBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try ListenBrainzScrobbler.saveToken(trimmed)
            listenBrainzTokenBuffer = ""
            listenBrainzStatus = "Saved."
        } catch {
            listenBrainzStatus = "Couldn't save to Keychain."
        }
    }

    private func testListenBrainzToken() {
        // Use either the freshly-typed token or the stored one.
        let candidate = listenBrainzTokenBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = candidate.isEmpty ? ListenBrainzScrobbler.storedToken() : candidate,
              !token.isEmpty else { return }
        listenBrainzTestInFlight = true
        listenBrainzStatus = nil
        Task {
            let result = await ListenBrainzScrobbler.validate(token: token)
            await MainActor.run {
                listenBrainzTestInFlight = false
                if result.valid {
                    listenBrainzStatus = result.username.map { "Connected — \($0)" } ?? "Connected."
                    if let name = result.username {
                        listenBrainzUsername = name
                        UserDefaults.standard.set(name, forKey: ScrobblerDefaults.listenBrainzUsername)
                    }
                } else {
                    listenBrainzStatus = result.message
                }
            }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func labeledSecureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var libraryAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Library access (advanced)")
            Text("Riff signs you in via Google's WebView flow which gives you full Library access through the YouTube Music cookie session — no setup required. The OAuth Device Flow path below is only useful if you want to access the YouTube Data API directly. Most users can ignore this.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Configure custom OAuth credentials") {
                VStack(alignment: .leading, spacing: 16) {
                    setupSteps
                    credentialsBlock
                }
                .padding(.top, 12)
            }
            .font(.system(size: 12, weight: .semibold))
            .tint(.white)
        }
    }

    /// "AI features" — BYO-LLM (Anthropic for now). The user
    /// pastes their own API key + picks a model; Riff uses it to
    /// power the Queue Builder ("vibe → queue") sheet. The key
    /// lives in Keychain, never UserDefaults, and never appears in
    /// logs or error messages.
    private var aiFeaturesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("AI features")
            Text("Pick a model backend — paid (Anthropic), free hosted (Groq), or fully local (Ollama). Whichever you pick powers the Queue Builder, lyrics translation, and X-Ray context cards. Keys live in Keychain and requests go straight from your Mac to the provider — Riff never proxies.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            // Backend picker. Segmented so all three options are
            // visible at a glance; the tagline below reads out of
            // whichever is currently selected.
            VStack(alignment: .leading, spacing: 6) {
                Text("Backend")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $activeProvider) {
                    ForEach(LLMProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: activeProvider) { _, new in
                    LLMProviderKind.active = new
                    // Any provider swap invalidates translations /
                    // X-Ray cards produced under the old backend —
                    // different model = different output, better to
                    // regenerate than to serve stale mixed-source
                    // content.
                    env.lyricsTranslator.clearCache()
                    env.xrayCardsService.clearCache()
                    aiTestResult = nil
                }
                Text(activeProvider.tagline)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only the selected backend's credential/model block is
            // rendered — reduces cognitive load and keeps the
            // Save/Test/Clear buttons in one place.
            switch activeProvider {
            case .anthropic: anthropicCredentialBlock
            case .groq:      groqCredentialBlock
            case .ollama:    ollamaCredentialBlock
            }

            translationLanguagePicker

            HStack {
                Button("Test connection") { testActiveProvider() }
                    .buttonStyle(.bordered)
                    .disabled(aiTestInFlight || !activeProvider.isConfigured())
                if aiTestInFlight {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Group {
                    if case .success = aiTestResult {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Connected").font(.system(size: 12)).foregroundStyle(.green)
                        }
                    } else if case .failure(let msg) = aiTestResult {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text(msg).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
                        }
                    } else if let status = aiSaveStatus {
                        Text(status).font(.system(size: 12)).foregroundStyle(.green)
                    }
                }
            }
        }
    }

    // MARK: - Per-provider credential blocks

    @ViewBuilder
    private var anthropicCredentialBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Anthropic API key").font(.system(size: 12, weight: .semibold))
            SecureField(
                AnthropicProvider.storedAPIKey() == nil ? "sk-ant-…" : "•••• saved — paste to replace",
                text: $anthropicAPIKey
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .onSubmit(saveAnthropicKey)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.system(size: 12, weight: .semibold))
            Picker("", selection: $anthropicModel) {
                ForEach(AnthropicProvider.availableModels, id: \.self) { id in
                    Text(modelDisplayName(id)).tag(id)
                }
            }
            .pickerStyle(.menu).labelsHidden()
            .onChange(of: anthropicModel) { _, new in AnthropicProvider.setModel(new) }
        }
        HStack {
            Button("Save key") { saveAnthropicKey() }
                .buttonStyle(.borderedProminent).tint(Theme.red)
                .disabled(anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if AnthropicProvider.storedAPIKey() != nil {
                Button("Clear") {
                    AnthropicProvider.clearAPIKey()
                    env.lyricsTranslator.clearCache()
                    env.xrayCardsService.clearCache()
                    anthropicAPIKey = ""
                    aiSaveStatus = "Anthropic key removed."
                    aiTestResult = nil
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var groqCredentialBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Groq API key").font(.system(size: 12, weight: .semibold))
            SecureField(
                GroqProvider.storedAPIKey() == nil ? "gsk_…" : "•••• saved — paste to replace",
                text: $groqAPIKey
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .onSubmit(saveGroqKey)
            Text("Free key at the Groq console — API Keys page. No credit card needed.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            if let url = URL(string: "https://console.groq.com/keys") {
                Link("console.groq.com/keys", destination: url)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.red.opacity(0.85))
                    .underline()
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.system(size: 12, weight: .semibold))
            Picker("", selection: $groqModel) {
                ForEach(GroqProvider.availableModels, id: \.self) { id in Text(id).tag(id) }
            }
            .pickerStyle(.menu).labelsHidden()
            .onChange(of: groqModel) { _, new in GroqProvider.setModel(new) }
        }
        HStack {
            Button("Save key") { saveGroqKey() }
                .buttonStyle(.borderedProminent).tint(Theme.red)
                .disabled(groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if GroqProvider.storedAPIKey() != nil {
                Button("Clear") {
                    GroqProvider.clearAPIKey()
                    env.lyricsTranslator.clearCache()
                    env.xrayCardsService.clearCache()
                    groqAPIKey = ""
                    aiSaveStatus = "Groq key removed."
                    aiTestResult = nil
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var ollamaCredentialBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ollama host").font(.system(size: 12, weight: .semibold))
            TextField("Default host", text: $ollamaBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(saveOllamaSettings)
            Text("Start the Ollama daemon on this Mac and paste its base URL. Default works for a stock install.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            if let url = URL(string: "https://ollama.com/download") {
                Link("ollama.com/download", destination: url)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.red.opacity(0.85))
                    .underline()
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Model").font(.system(size: 12, weight: .semibold))
            TextField(OllamaProvider.defaultModel, text: $ollamaModel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(saveOllamaSettings)
            Text("Any model you've pulled locally. Small + capable picks: qwen2.5:3b, gemma2:2b, llama3.2:3b.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
        HStack {
            Button("Save") { saveOllamaSettings() }
                .buttonStyle(.borderedProminent).tint(Theme.red)
            Spacer()
        }
    }

    /// Picker + "Other..." textfield for the lyrics-translation target
    /// language (B3). Selection routes through `env.translationLanguage`
    /// so it's persisted globally; the SwiftUI binding owns the picker
    /// state via a computed binding that maps the "Other" sentinel to
    /// the free-text buffer.
    @ViewBuilder
    private var translationLanguagePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lyrics translation language")
                .font(.system(size: 12, weight: .semibold))
            // Compute the picker selection: if the current language is
            // one of the presets, show it directly; otherwise fall
            // through to the "Other..." sentinel and surface the free
            // text in the buffer field.
            let isPreset = LyricsTranslator.presetLanguages.contains(env.translationLanguage)
            let selection = Binding<String>(
                get: { isPreset ? env.translationLanguage : Self.otherLanguageSentinel },
                set: { new in
                    if new == Self.otherLanguageSentinel {
                        // Flip to Other... — seed the buffer with the
                        // existing custom value (or a sensible default)
                        // and let the user edit. Don't overwrite
                        // env.translationLanguage until they type.
                        customLanguageBuffer = isPreset ? "" : env.translationLanguage
                    } else {
                        env.translationLanguage = new
                    }
                }
            )
            Picker("", selection: selection) {
                ForEach(LyricsTranslator.presetLanguages, id: \.self) { lang in
                    Text(lang).tag(lang)
                }
                Divider()
                Text(Self.otherLanguageSentinel).tag(Self.otherLanguageSentinel)
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if !isPreset || selection.wrappedValue == Self.otherLanguageSentinel {
                TextField(
                    "e.g. Portuguese, Russian, Vietnamese",
                    text: $customLanguageBuffer
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onAppear {
                    // Seed the buffer from env on first appearance so
                    // the field shows the persisted custom language
                    // (instead of being blank) when reopening Settings.
                    if customLanguageBuffer.isEmpty {
                        customLanguageBuffer = env.translationLanguage
                    }
                }
                .onSubmit(saveCustomLanguage)
                Button("Apply") { saveCustomLanguage() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(customLanguageBuffer.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Used when you turn on translation on the Now Playing lyrics tab. Translations are cached per song and language for the current session.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveCustomLanguage() {
        let trimmed = customLanguageBuffer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        env.translationLanguage = trimmed
        // Cache invalidates implicitly — the cache key includes the
        // language, so switching to a new one just won't hit a cached
        // entry. We don't clearCache() here because the user might
        // toggle between two languages back and forth.
    }

    private func modelDisplayName(_ id: String) -> String {
        switch id {
        case "claude-haiku-4-5-20251001": return "Claude Haiku 4.5 (fast, recommended)"
        case "claude-sonnet-4-6":         return "Claude Sonnet 4.6 (smarter)"
        default: return id
        }
    }

    private func saveAnthropicKey() {
        let trimmed = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try AnthropicProvider.setAPIKey(trimmed)
            anthropicAPIKey = "" // clear buffer; SecureField placeholder now reads "saved"
            aiSaveStatus = "Saved to Keychain."
            aiTestResult = nil
        } catch {
            // Don't leak the key into the error message — only the
            // failure mode (almost always a Keychain ACL prompt the
            // user denied).
            aiSaveStatus = "Couldn't save to Keychain."
        }
    }

    private func testAnthropicConnection() { testActiveProvider() }

    /// Round-trips a one-word prompt against whichever backend is
    /// currently selected. Cheap smoke-test — all three providers
    /// return in <500ms on a healthy setup and cost effectively
    /// nothing (Anthropic: <5 output tokens; Groq/Ollama: free).
    private func testActiveProvider() {
        aiTestInFlight = true
        aiTestResult = nil
        aiSaveStatus = nil
        let kind = activeProvider
        let provider = kind.makeProvider()
        let model = kind.currentModel()
        Task {
            do {
                _ = try await provider.chat([.user("Reply with the single word: ok")], model: model)
                await MainActor.run {
                    aiTestResult = .success
                    aiTestInFlight = false
                }
            } catch let err as LLMError {
                await MainActor.run {
                    aiTestResult = .failure(err.errorDescription ?? "Couldn't reach \(kind.displayName).")
                    aiTestInFlight = false
                }
            } catch {
                await MainActor.run {
                    aiTestResult = .failure("Couldn't reach \(kind.displayName).")
                    aiTestInFlight = false
                }
            }
        }
    }

    private func saveGroqKey() {
        let trimmed = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try GroqProvider.setAPIKey(trimmed)
            groqAPIKey = ""
            aiSaveStatus = "Groq key saved to Keychain."
            aiTestResult = nil
        } catch {
            aiSaveStatus = "Couldn't save Groq key."
        }
    }

    private func exportDiagnostics() {
        diagnosticsExporting = true
        diagnosticsStatus = nil
        Task {
            let result = await DiagnosticsExporter.exportDiagnostics()
            await MainActor.run {
                diagnosticsExporting = false
                switch result {
                case .success(let url):
                    diagnosticsStatus = "Saved to \(url.lastPathComponent) — revealed in Finder."
                case .failure(let msg):
                    diagnosticsStatus = msg
                }
            }
        }
    }

    private func saveOllamaSettings() {
        OllamaProvider.setBaseURL(ollamaBaseURL)
        OllamaProvider.setModel(ollamaModel)
        // Re-hydrate the buffers from the store so the user sees the
        // normalized values (trimmed / defaulted) rather than raw input.
        ollamaBaseURL = OllamaProvider.storedBaseURL().absoluteString
        ollamaModel = OllamaProvider.storedModel()
        aiSaveStatus = "Ollama settings saved."
        aiTestResult = nil
    }

    /// "Blocked artists" — manage the list the user built via the
    /// "Don't recommend this artist" context-menu action. Only shown
    /// when the list is non-empty; nothing to manage otherwise.
    private var blockedArtistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Blocked artists")
            Text("Tracks by these artists are hidden from Home, Search, and the radio queue. Note: when a track ends naturally, YouTube Music's autoplay can still pick a blocked artist — we filter what we show, not what YT plays.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            // Display the captured artist name (falls back to id only
            // for legacy entries migrated from the old Set<String>
            // storage — those upgrade on the next re-block).
            ForEach(env.blockedArtistIds, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(env.blockedArtistName(id: id))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                        Text(id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Unblock") {
                        env.unblockArtist(id: id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// D2 — list of per-track metadata overrides. Hidden when empty
    /// (gated on the call site). Per-row "Remove" plus a "Clear all"
    /// action at the bottom so the section never traps the user with
    /// dozens of accumulated overrides.
    private var trackOverridesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Track metadata overrides")
            Text("Title / artist / album corrections you've applied to individual tracks. Local-only — nothing is sent to YouTube. To re-edit, right-click a track row anywhere in the app.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(env.trackOverrides.sortedVideoIds, id: \.self) { videoId in
                if let override = env.trackOverrides.override(for: videoId) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            // Compact summary: prefer the override
                            // title; fall back to the videoId if the
                            // user only overrode artist or album.
                            Text(override.title ?? override.artist ?? videoId)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                            if let a = override.artist, override.title != nil {
                                Text(a)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                            if let a = override.album {
                                Text(a)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                            Text(videoId)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Remove") {
                            env.trackOverrides.clearOverride(videoId: videoId)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Spacer()
                Button("Clear all overrides", role: .destructive) {
                    confirmClearOverrides = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .confirmationDialog(
                    "Clear all track overrides?",
                    isPresented: $confirmClearOverrides,
                    titleVisibility: .visible
                ) {
                    Button("Clear all overrides", role: .destructive) {
                        env.trackOverrides.clearAll()
                        env.showToast("All track overrides cleared.")
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes every locally-edited title, artist, and album name. This action can't be undone.")
                }
            }
            .padding(.top, 4)
        }
    }

    /// "Export diagnostics" — writes a folder to ~/Downloads with
    /// the last 24 h of Riff's os_log entries + the played-history
    /// journal + a small manifest (app + macOS version). No API
    /// keys, no cookies, no OAuth tokens. Reveals the folder in
    /// Finder so the user can attach it to a bug report in one
    /// gesture.
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Diagnostics")
            Text("Export a folder to ~/Downloads with recent Riff logs, your played-history journal, and version info. Useful when filing a bug report. Contains no API keys, cookies, or account identifiers.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    exportDiagnostics()
                } label: {
                    if diagnosticsExporting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Exporting…")
                        }
                    } else {
                        Label("Export diagnostics", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .disabled(diagnosticsExporting)
                Spacer()
                if let msg = diagnosticsStatus {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(msg.hasPrefix("Saved") ? .green : .red)
                        .lineLimit(2)
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("About")
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Riff")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Native macOS YouTube Music client • AGPL-3.0")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Text("v0.1.0")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.75))
    }

    private func shortcutRow(_ label: String, keys: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(keys)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Library access")
                .font(.system(size: 22, weight: .bold))
            Text("Riff signs you in via Google's Device Flow using a public YouTube TV OAuth client. That works for sign-in, but the underlying Google Cloud project doesn't expose the YouTube Data API — which is what we need to read your liked songs and playlists.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Text("To unlock the Library tab, register your own OAuth Limited-Input client in Google Cloud (free, ~5 min) and paste the credentials below.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setup")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .textCase(.uppercase)
                .tracking(1.2)

            stepRow(n: 1, title: "Open Google Cloud Console") {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!)
                } label: {
                    Label("Open Cloud Console", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }
            stepRow(n: 2, title: "Enable the YouTube Data API v3 on a new or existing project.") { EmptyView() }
            stepRow(n: 3, title: "Go to Credentials → Create Credentials → OAuth client ID. Pick \u{201C}TVs and Limited Input devices\u{201D} as the application type.") { EmptyView() }
            stepRow(n: 4, title: "Copy the client ID and client secret into the fields below and click Save.") { EmptyView() }
        }
    }

    private func stepRow<Content: View>(n: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.red)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.06))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private var credentialsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OAuth credentials")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .textCase(.uppercase)
                .tracking(1.2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Client ID")
                    .font(.system(size: 12, weight: .semibold))
                TextField("xxxxxxxxx-xxxxxxxx.apps.googleusercontent.com", text: $clientId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Client secret")
                    .font(.system(size: 12, weight: .semibold))
                SecureField("GOCSPX-…", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack {
                Button("Save & sign out") {
                    let config = OAuthClientConfig(
                        clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
                        clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    config.save()
                    env.signOut()
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .disabled(clientId.isEmpty || clientSecret.isEmpty)

                Button("Reset to defaults") {
                    OAuthClientConfig.reset()
                    clientId = ""
                    clientSecret = ""
                    env.signOut()
                }
                .buttonStyle(.bordered)

                if saved {
                    Text("Saved. Sign in again to use the new credentials.")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
            }
            .padding(.top, 4)
        }
    }
}
