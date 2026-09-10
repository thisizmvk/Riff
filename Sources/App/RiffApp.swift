import SwiftUI
import AppKit
import Combine

/// Bridges AppKit's Dock-menu callback into the SwiftUI app. The Dock
/// icon is the one surface guaranteed visible for every user (unlike
/// the opt-in menu-bar and floating mini players), and Spotify /
/// Music.app both put transport controls there. `env` is injected by
/// RiffApp at init; the menu is rebuilt on every right-click, so it
/// always reflects live player state.
final class RiffAppDelegate: NSObject, NSApplicationDelegate {
    var env: AppEnvironment?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let env else { return nil }
        let menu = NSMenu()
        if let track = env.player.currentTrack {
            let info = NSMenuItem(title: "\(track.title) — \(track.subtitle)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(.separator())
        }
        let playPause = NSMenuItem(
            title: env.player.isPlaying ? "Pause" : "Play",
            action: #selector(dockTogglePlay), keyEquivalent: ""
        )
        playPause.target = self
        menu.addItem(playPause)
        let next = NSMenuItem(title: "Next Track", action: #selector(dockNext), keyEquivalent: "")
        next.target = self
        menu.addItem(next)
        let prev = NSMenuItem(title: "Previous Track", action: #selector(dockPrevious), keyEquivalent: "")
        prev.target = self
        menu.addItem(prev)
        return menu
    }

    @MainActor @objc private func dockTogglePlay() {
        guard let env else { return }
        Task { await env.player.togglePlay() }
    }
    @MainActor @objc private func dockNext() {
        guard let env else { return }
        Task { await env.player.next() }
    }
    @MainActor @objc private func dockPrevious() {
        guard let env else { return }
        Task { await env.player.previous() }
    }
}

@main
struct RiffApp: App {
    @State private var environment = AppEnvironment()
    @NSApplicationDelegateAdaptor(RiffAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.env = environment }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                AccountCommandItems()
                Button("Settings…") { environment.isSettingsSheetPresented = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                MiniPlayerMenuItem()
            }
            CommandGroup(before: .toolbar) {
                TabSwitchMenuItems()
                Divider()
                // Riff can produce share links; this lets it consume one.
                Button("Open YouTube Music Link from Clipboard") {
                    environment.openLinkFromPasteboard()
                }
                // ⌘⇧O — ⌘⇧L is already Sign In.
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
            }
            // Transport shortcuts — Space play/pause, ⌘← / ⌘→ for prev/next
            // track, ⌘↑ / ⌘↓ for volume nudge, ⌥⌘← / ⌥⌘→ for ±15 / ±30s
            // skip. Wired through `@FocusedValue(\.appEnvironment)` so the
            // bindings hit the active window's PlayerBridge.
            CommandMenu("Playback") {
                TransportMenuItems()
            }
            CommandGroup(replacing: .help) {
                RecapMenuItem()
                Divider()
                Button("Riff on GitHub") {
                    if let url = URL(string: "https://github.com/mvk24199/Riff") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/mvk24199/Riff/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("View License (AGPL-3.0)") {
                    if let url = URL(string: "https://www.gnu.org/licenses/agpl-3.0.en.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Always-on-top compact playback tile in a separate window.
        // Open via Window → Mini Player (⌥⌘M). The user can grow the
        // window past the 280×140 minimum — the artwork fills whatever
        // size they pick — but cannot shrink below it.
        Window("Mini Player", id: "mini-player") {
            FloatingMiniPlayerView()
                .environment(environment)
        }
        .defaultSize(width: 320, height: 180)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        // System menu-bar mini player. Compact transport + scrubber that
        // lives next to the system clock, so the user can pause/skip
        // without bringing Riff's main window forward. Toggleable via the
        // Settings sheet (`AppEnvironment.menuBarExtraEnabled`); the
        // binding makes the `MenuBarExtra` add/remove itself live without
        // a relaunch.
        //
        // Same `env.player` as everywhere else — no second WKWebView.
        MenuBarExtra(isInserted: menuBarExtraInsertedBinding) {
            MenuBarMiniPlayer()
                .environment(environment)
        } label: {
            MenuBarMiniPlayerLabel()
                .environment(environment)
        }
        .menuBarExtraStyle(.window)
    }

    /// Bridges the `@State` AppEnvironment value into a `Binding<Bool>`
    /// the `MenuBarExtra` `isInserted:` parameter accepts. We can't take
    /// `$environment.menuBarExtraEnabled` directly because AppEnvironment
    /// is an `@Observable` class held by `@State`, not a struct.
    private var menuBarExtraInsertedBinding: Binding<Bool> {
        Binding(
            get: { environment.menuBarExtraEnabled },
            set: { environment.menuBarExtraEnabled = $0 }
        )
    }
}

/// Help menu entry that surfaces the always-on Stats sheet (formerly
/// "Your Riff Highlights"). Lives in its own struct so it can read
/// `@FocusedValue(\.appEnvironment)`, which the CommandGroup builder
/// otherwise can't reach.
///
/// Renamed in B1 to reflect the year-round framing: the same sheet
/// now exposes 7-day / 30-day / 90-day / all-time windows via a
/// picker, so calling it "Highlights" undersold what it does.
private struct RecapMenuItem: View {
    @FocusedValue(\.appEnvironment) private var env

    var body: some View {
        Button("Stats…") {
            env?.isRecapSheetPresented = true
        }
        .keyboardShortcut("Y", modifiers: [.command, .shift])
        .disabled(env == nil)
    }
}

/// Sign In / Sign Out menu-bar item. Extracted into its own View —
/// reading the env via `@FocusedValue` — so it participates in
/// SwiftUI's observation graph and flips label immediately when
/// `isSignedIn` changes. Inlining the `if environment.isSignedIn`
/// check directly in the `CommandGroup` builder snapshotted the
/// value and left the menu item stale until relaunch. ⇧⌘L keeps
/// working as the Sign In shortcut when signed out.
private struct AccountCommandItems: View {
    @FocusedValue(\.appEnvironment) private var env

    var body: some View {
        if env?.isSignedIn == true {
            Button("Sign Out") { env?.signOut() }
                .disabled(env == nil)
        } else {
            Button("Sign In…") { env?.isSignInSheetPresented = true }
                .keyboardShortcut("L", modifiers: [.command, .shift])
                .disabled(env == nil)
        }
    }
}

/// Re-usable menu item that opens the Mini Player window. Lives in its
/// own struct so it can use `@Environment(\.openWindow)`.
private struct MiniPlayerMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Mini Player") { openWindow(id: "mini-player") }
            .keyboardShortcut("M", modifiers: [.command, .option])
    }
}

/// View menu entries that switch the active main tab via ⌘1 / ⌘2 / ⌘3 / ⌘4.
/// Promoted out of MainTabs so we can read the AppEnvironment at the
/// command-builder layer.
private struct TabSwitchMenuItems: View {
    @FocusedValue(\.appEnvironment) private var env

    var body: some View {
        Button("Command Palette…") { env?.isCommandPaletteOpen = true }
            .keyboardShortcut("K", modifiers: .command)
            .disabled(env == nil)
        Button("Find (Search)") { env?.focusSearchField() }
            .keyboardShortcut("F", modifiers: .command)
            .disabled(env == nil)
        Divider()
        Button("Home") { env?.activeTab = .home }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(env == nil)
        Button("Explore") { env?.activeTab = .explore }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(env == nil)
        Button("Search") { env?.activeTab = .search }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(env == nil)
        Button("Library") { env?.activeTab = .library }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(env == nil)
    }
}

/// Playback menu — exposes Space (play/pause), arrow-key transport,
/// and volume-nudge shortcuts at the App command-builder layer. Lives
/// in its own struct so it can read `@FocusedValue(\.appEnvironment)`
/// to drive the active window's PlayerBridge. Disabled when the
/// PlayerBridge isn't available (no main window focused).
private struct TransportMenuItems: View {
    @FocusedValue(\.appEnvironment) private var env

    var body: some View {
        Button("Play / Pause") {
            guard let env else { return }
            Task { await env.player.togglePlay() }
        }
        // Space is the universal play/pause shortcut. Modifier-less so
        // it works without ⌘ — matches Apple Music, Spotify, YT Music.
        .keyboardShortcut(.space, modifiers: [])
        .disabled(env?.player.hasTrack != true)

        Button("Next Track") {
            guard let env else { return }
            Task { await env.player.next() }
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(env?.player.hasTrack != true)

        Button("Previous Track") {
            guard let env else { return }
            Task { await env.player.previous() }
        }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(env?.player.hasTrack != true)

        Divider()

        Button("Skip Forward 30s") {
            guard let env else { return }
            Task { await env.player.skip(by: 30) }
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(env?.player.hasTrack != true)

        Button("Skip Back 15s") {
            guard let env else { return }
            Task { await env.player.skip(by: -15) }
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(env?.player.hasTrack != true)

        Divider()

        Button("Volume Up") {
            guard let env else { return }
            // Step ~7% per press — coarse enough that holding the
            // shortcut moves volume audibly between repeats.
            let next = min(1.0, env.player.volume + 0.07)
            Task { await env.player.setVolume(next) }
        }
        .keyboardShortcut(.upArrow, modifiers: .command)

        Button("Volume Down") {
            guard let env else { return }
            let next = max(0.0, env.player.volume - 0.07)
            Task { await env.player.setVolume(next) }
        }
        .keyboardShortcut(.downArrow, modifiers: .command)

        Divider()

        Button("Toggle Like") {
            guard let env else { return }
            Task { await env.player.toggleLike() }
        }
        .keyboardShortcut("L", modifiers: .command)
        .disabled(env?.player.hasTrack != true)

        Divider()

        Button("Toggle Shuffle") {
            env?.player.toggleShuffle()
        }
        .keyboardShortcut("S", modifiers: [.command, .shift])

        Button("Cycle Repeat") {
            guard let env else { return }
            Task { await env.player.toggleRepeat() }
        }
        .keyboardShortcut("R", modifiers: [.command, .shift])
    }
}

/// FocusedValueKey that lets `CommandGroup` content reach the active
/// window's AppEnvironment. Set in RootView via `.focusedSceneValue`.
private struct AppEnvironmentFocusKey: FocusedValueKey {
    typealias Value = AppEnvironment
}
extension FocusedValues {
    fileprivate var appEnvironment: AppEnvironment? {
        get { self[AppEnvironmentFocusKey.self] }
        set { self[AppEnvironmentFocusKey.self] = newValue }
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var env = env
        ZStack {
            // The tabs stay MOUNTED while Now Playing is open. They used
            // to be swapped out, which re-created every tab view on each
            // close: Search lost its query and results, Library and
            // Explore refetched, scroll positions reset. Now Playing is
            // opaque; the covered tabs layer is hidden, non-hit-testable
            // and disabled (so no stray keyboard focus lives under it).
            // The old "content leaked through" was the ZStack backdrop-
            // inflation bug, since fixed by moving backdrops into
            // `.background {}`.
            ZStack(alignment: .bottom) {
                MainTabs()
                if env.player.hasTrack {
                    MiniPlayerView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .opacity(env.player.isFullPlayerOpen ? 0 : 1)
            .allowsHitTesting(!env.player.isFullPlayerOpen)
            .disabled(env.player.isFullPlayerOpen)
            .accessibilityHidden(env.player.isFullPlayerOpen)
            if env.player.isFullPlayerOpen {
                NowPlayingView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.panel, value: env.player.isFullPlayerOpen)
        .background(Theme.Bg.base.ignoresSafeArea())
        .focusedSceneValue(\.appEnvironment, env)
        .overlay(alignment: .bottom) {
            // Toast overlay. Slides in above the mini-player when
            // env.currentToast is non-nil; auto-dismisses via the
            // env-side timer or on Undo tap.
            if let toast = env.currentToast {
                ToastBanner(toast: toast) { env.dismissToast() }
                    .padding(.bottom, env.player.hasTrack ? 88 : 20)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // NOT .isModal — that told VoiceOver to ignore the
                    // entire window for the toast's 3-second life.
                    // Announcement happens in showToast instead.
            }
        }
        .animation(.easeOut(duration: 0.2), value: env.currentToast)
        .sheet(isPresented: $env.isSignInSheetPresented) {
            SignInView()
        }
        .sheet(isPresented: $env.isSettingsSheetPresented) {
            SettingsView()
        }
        .sheet(isPresented: $env.isNewPlaylistSheetPresented) {
            NewPlaylistSheet()
        }
        .sheet(isPresented: $env.isRecapSheetPresented) {
            RecapView()
        }
        .sheet(isPresented: $env.isLyricCardSheetPresented) {
            LyricCardSheet()
        }
        .sheet(isPresented: $env.isQueueBuilderSheetPresented) {
            QueueBuilderSheet()
        }
        .sheet(isPresented: $env.isCommandPaletteOpen) {
            CommandPalette()
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $env.isOnboardingSheetPresented) {
            OnboardingSheet()
        }
        // D2 — Edit-metadata sheet. `item:` binding mode so the sheet
        // is parameterized by the row the user opened it from.
        .sheet(item: Binding(
            get: { env.trackBeingEdited },
            set: { env.trackBeingEdited = $0 }
        )) { item in
            EditMetadataSheet(item: item)
        }
        .onReceive(NotificationCenter.default.publisher(for: .riffOpenMiniPlayerWindow)) { _ in
            openWindow(id: "mini-player")
        }
    }
}

struct MainTabs: View {
    @Environment(AppEnvironment.self) private var env
    /// Tabs mount on first visit and STAY mounted. A `switch` gave each
    /// tab a distinct structural identity, so every switch destroyed
    /// the outgoing view: Search lost its query and results, Explore
    /// re-skeletoned and refetched, Library refired its loads (27
    /// requests on Artists), Home re-pulled seven shelves. Unvisited
    /// tabs cost nothing until first shown.
    @State private var mounted: Set<AppTab> = []

    var body: some View {
        VStack(spacing: 0) {
            TopTabBar()
            ZStack {
                if mounted.contains(.home)    { HomeView().tabPane(active: env.activeTab == .home) }
                if mounted.contains(.explore) { ExploreView().tabPane(active: env.activeTab == .explore) }
                if mounted.contains(.search)  { SearchView().tabPane(active: env.activeTab == .search) }
                if mounted.contains(.library) { LibraryView().tabPane(active: env.activeTab == .library) }
            }
            .onChange(of: env.activeTab, initial: true) { _, tab in
                mounted.insert(tab)
            }
        }
    }
}

/// An inactive, still-mounted tab: invisible, untouchable, disabled
/// (no keyboard focus or shortcuts fire underneath the visible tab),
/// hidden from accessibility, and below the active one.
private struct TabPane: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .disabled(!active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
    }
}

private extension View {
    func tabPane(active: Bool) -> some View { modifier(TabPane(active: active)) }
}

struct TopTabBar: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 24) {
            tab("Home", .home)
            tab("Explore", .explore)
            tab("Search", .search)
            tab("Library", .library)
            Spacer()
            AccountMenu()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func tab(_ title: String, _ value: AppTab) -> some View {
        Button(action: {
            // Tapping the already-active tab pops its NavigationStack to
            // the root (so "Home" returns to the home grid even when the
            // user is deep inside an album/playlist detail page).
            if env.activeTab == value {
                switch value {
                case .home:    env.homeNavPath = NavigationPath()
                case .explore: env.exploreNavPath = NavigationPath()
                case .search:  env.searchNavPath = NavigationPath()
                case .library: env.libraryNavPath = NavigationPath()
                }
            } else {
                env.activeTab = value
            }
        }) {
            Text(title)
                .font(.system(size: 15, weight: env.activeTab == value ? .semibold : .regular))
                .foregroundStyle(env.activeTab == value ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) tab")
        .accessibilityHint(env.activeTab == value
                           ? "Selected. Double tap to return to top."
                           : "Double tap to switch tabs.")
        .accessibilityAddTraits(env.activeTab == value ? [.isButton, .isSelected] : .isButton)
    }
}

/// Top-right corner. Shows a "Sign In" pill when anonymous, a circular
/// initial avatar with a Menu (Sign Out) when authenticated. Lets users
/// see and manage auth state without going to the menu bar.
private struct AccountMenu: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // Always a Menu with a STABLE identity — the label + items
        // vary by sign-in state, but the view itself is never
        // swapped for a different type. Swapping Menu ⇄ Button in
        // this slot caused the corner to go empty after Sign Out:
        // SwiftUI tore down the Menu mid-action and didn't render
        // the replacement Button until a later layout pass.
        Menu {
            if env.isSignedIn {
                Button("Settings…") { env.isSettingsSheetPresented = true }
                Divider()
                Button("Switch Account…") {
                    // Sign out (clears cookies + purges WebView),
                    // then open a fresh Google login so the user
                    // can switch accounts without hunting for two
                    // separate actions.
                    env.signOut()
                    env.isSignInSheetPresented = true
                }
                Button("Sign Out") { env.signOut() }
            } else {
                Button("Sign In with Google") { env.isSignInSheetPresented = true }
                Divider()
                Button("Settings…") { env.isSettingsSheetPresented = true }
            }
        } label: {
            if env.isSignedIn {
                Circle()
                    .fill(Theme.red)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Sign In")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.red)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(env.isSignedIn ? "Account" : "Sign in")
    }
}

/// Transient toast banner. Renders a rounded pill with the message
/// on the left and an optional "Undo" button on the right. Sits
/// above the mini-player when one is present; over the tab bar
/// otherwise. Auto-dismisses via the AppEnvironment-side timer;
/// tapping Undo runs the callback and dismisses immediately.
private struct ToastBanner: View {
    let toast: AppEnvironment.Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 12)
            if let undo = toast.undo {
                Button("Undo") {
                    undo()
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.red)
                .accessibilityHint("Undoes the last action.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Color(white: 0.15))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        )
        .frame(maxWidth: 480)
        .accessibilityElement(children: .combine)
    }
}
