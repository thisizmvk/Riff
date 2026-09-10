import SwiftUI

/// ⌘K command palette. Fuzzy launcher over app-wide actions: switch
/// tabs, toggle playback modes, arm sleep timer / crossfade presets,
/// open sheets. Scoped to what's already in `AppEnvironment` /
/// `PlayerBridge` so no new state to persist and no new networking.
///
/// Design contract: keyboard-only navigation. ↑/↓ move selection,
/// ↵ runs the highlighted action, Esc dismisses. The search field
/// is auto-focused on open. Mouse works too (hover to highlight,
/// click to run).
struct CommandPalette: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.Theme.Text.tertiary)
                    .font(.system(size: 14, weight: .medium))
                TextField("Jump to…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit { runSelected() }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.Theme.Text.disabled)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().background(Theme.divider)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredActions.enumerated()), id: \.element.id) { idx, action in
                            row(action: action, selected: idx == selectedIndex)
                                .id(idx)
                                .onTapGesture { run(action) }
                                .onHover { hovering in
                                    if hovering { selectedIndex = idx }
                                }
                        }
                        if filteredActions.isEmpty {
                            Text("No matches")
                                .font(.system(size: 13))
                                .foregroundStyle(.Theme.Text.disabled)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 20)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }

            Divider().background(Theme.divider)

            HStack(spacing: 12) {
                hint(key: "↑↓", label: "navigate")
                hint(key: "↵", label: "select")
                hint(key: "esc", label: "close")
                Spacer()
                Text("\(filteredActions.count) result\(filteredActions.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.Theme.Text.disabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile)
                .fill(Color(white: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile)
                .strokeBorder(Theme.Fill.medium, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
        .onAppear {
            searchFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            // Any query edit clamps selection back to the top of the
            // freshly-filtered list so the user's next ↵ hits the
            // closest match, not a stale index into the old list.
            selectedIndex = 0
        }
        // SwiftUI's `.onKeyPress` bubbles past focused TextFields for
        // keys the field doesn't itself consume — up/down arrows are
        // caret nav for multi-line but no-op for single-line, so they
        // reach us here. Return-through-text-field is wired via the
        // TextField's own `.onSubmit`.
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
    }

    private func row(action: PaletteAction, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: action.icon)
                .frame(width: 22, height: 22)
                .foregroundStyle(selected ? .white : .Theme.Text.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .Theme.Text.secondary)
                if let subtitle = action.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.Theme.Text.tertiary)
                }
            }
            Spacer()
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Fill.medium)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.Theme.Text.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Theme.red.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    private func hint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.Fill.medium)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.Theme.Text.tertiary)
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = filteredActions.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    private func runSelected() {
        guard filteredActions.indices.contains(selectedIndex) else { return }
        run(filteredActions[selectedIndex])
    }

    private func run(_ action: PaletteAction) {
        env.isCommandPaletteOpen = false
        // Defer the actual work to the next runloop tick so the sheet's
        // dismiss animation and any sheet the action wants to raise
        // don't collide. Task { @MainActor in … } — rather than
        // DispatchQueue.main.async — so calls into AppEnvironment's
        // MainActor-isolated setters compile under Swift 6 strict
        // concurrency.
        Task { @MainActor in
            action.action(env)
        }
    }

    // MARK: - Action catalog

    private var allActions: [PaletteAction] {
        var actions: [PaletteAction] = []

        // Tabs.
        actions.append(.tab("Home", icon: "house.fill", tab: .home))
        actions.append(.tab("Explore", icon: "sparkles", tab: .explore))
        actions.append(.tab("Search", icon: "magnifyingglass", tab: .search))
        actions.append(.tab("Library", icon: "books.vertical.fill", tab: .library))

        // Sheets / windows.
        actions.append(PaletteAction(
            id: "settings",
            title: "Settings",
            subtitle: "Preferences, sign-in, playback",
            icon: "gearshape.fill",
            shortcut: "⌘,"
        ) { $0.isSettingsSheetPresented = true })
        actions.append(PaletteAction(
            id: "stats",
            title: "Stats",
            subtitle: "Recap of what you've been playing",
            icon: "chart.bar.fill",
            shortcut: "⇧⌘Y"
        ) { $0.isRecapSheetPresented = true })
        actions.append(PaletteAction(
            id: "mini-player",
            title: "Mini Player",
            subtitle: "Open the always-on-top tile",
            icon: "rectangle.on.rectangle.angled",
            shortcut: "⌥⌘M"
        ) { _ in
            // `@Environment(\.openWindow)` isn't reachable from a sheet
            // that lives outside the WindowGroup; hop through the
            // observer wired on RootView.
            NotificationCenter.default.post(name: .riffOpenMiniPlayerWindow, object: nil)
        })
        actions.append(PaletteAction(
            id: "queue-builder",
            title: "Build queue from a vibe",
            subtitle: "AI-generated queue",
            icon: "wand.and.stars"
        ) { $0.isQueueBuilderSheetPresented = true })
        actions.append(PaletteAction(
            id: "new-playlist",
            title: "New playlist",
            icon: "plus.rectangle.on.folder"
        ) { $0.isNewPlaylistSheetPresented = true })
        actions.append(PaletteAction(
            id: "signin",
            title: env.isSignedIn ? "Sign out" : "Sign in with Google",
            subtitle: env.isSignedIn ? "Disconnect Google account" : "Remove ads (with Premium) + sync your library",
            icon: env.isSignedIn ? "arrow.right.square" : "person.crop.circle.badge.plus"
        ) { e in
            if e.isSignedIn { e.signOut() } else { e.isSignInSheetPresented = true }
        })

        // Playback.
        let isPlaying = env.player.isPlaying
        actions.append(PaletteAction(
            id: "toggle-play",
            title: isPlaying ? "Pause" : "Play",
            icon: isPlaying ? "pause.fill" : "play.fill",
            shortcut: "space"
        ) { e in Task { await e.player.togglePlay() } })
        actions.append(PaletteAction(
            id: "next",
            title: "Next track",
            icon: "forward.end.fill",
            shortcut: "⌘→"
        ) { e in Task { await e.player.next() } })
        actions.append(PaletteAction(
            id: "prev",
            title: "Previous track",
            icon: "backward.end.fill",
            shortcut: "⌘←"
        ) { e in Task { await e.player.previous() } })
        actions.append(PaletteAction(
            id: "shuffle",
            title: env.player.shuffleEnabled ? "Turn shuffle off" : "Turn shuffle on",
            icon: "shuffle",
            shortcut: "⇧⌘S"
        ) { e in e.player.toggleShuffle() })
        actions.append(PaletteAction(
            id: "smart-shuffle",
            title: env.player.smartShuffleEnabled ? "Turn Smart Shuffle off" : "Turn Smart Shuffle on",
            subtitle: "Sprinkle related songs into your queue",
            icon: "wand.and.rays"
        ) { e in e.player.toggleSmartShuffle() })
        actions.append(PaletteAction(
            id: "repeat",
            title: env.player.repeatMode == .off ? "Turn repeat on" : "Turn repeat off",
            icon: env.player.repeatMode == .one ? "repeat.1" : "repeat",
            shortcut: "⇧⌘R"
        ) { e in Task { await e.player.toggleRepeat() } })
        if env.player.currentTrack != nil {
            actions.append(PaletteAction(
                id: "like",
                title: env.player.liked ? "Remove from liked" : "Like this track",
                icon: env.player.liked ? "heart.fill" : "heart",
                shortcut: "⌘L"
            ) { e in Task { await e.player.toggleLike() } })
            actions.append(PaletteAction(
                id: "save-queue",
                title: "Save queue as playlist",
                subtitle: "\(env.player.upNext.count) tracks in Up Next",
                icon: "square.and.arrow.down"
            ) { e in
                Task {
                    try? await e.player.savePlaylistFromQueue(title: "Queue — \(shortDate())")
                }
            })
        }

        // Sleep-timer presets.
        for minutes in [5, 10, 15, 30, 45, 60] {
            actions.append(PaletteAction(
                id: "sleep-\(minutes)",
                title: "Sleep in \(minutes) min",
                subtitle: "Fade-out at end",
                icon: "moon.zzz.fill"
            ) { e in e.player.setSleepTimer(minutes: minutes, mode: .fadeOut) })
        }
        if env.player.sleepTimerRemaining != nil {
            actions.append(PaletteAction(
                id: "sleep-cancel",
                title: "Cancel sleep timer",
                icon: "moon.zzz"
            ) { e in e.player.cancelSleepTimer() })
        }

        // Crossfade presets.
        for seconds in PlayerBridge.crossfadePresets {
            let title = seconds == 0 ? "Crossfade off" : "Crossfade \(Int(seconds))s"
            actions.append(PaletteAction(
                id: "crossfade-\(Int(seconds))",
                title: title,
                icon: "waveform.path.ecg"
            ) { e in Task { await e.player.setCrossfadeSeconds(seconds) } })
        }

        // Normalization toggle.
        actions.append(PaletteAction(
            id: "norm",
            title: env.player.normalizationEnabled ? "Turn volume normalization off" : "Turn volume normalization on",
            subtitle: "Match loudness across tracks",
            icon: "speaker.wave.2.fill"
        ) { e in Task { await e.player.setNormalizationEnabled(!e.player.normalizationEnabled) } })

        return actions
    }

    private var filteredActions: [PaletteAction] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allActions }
        // Rank: title-prefix > word-start > substring > subtitle-substring.
        // Ties broken by original catalog order (stable).
        struct Scored { let score: Int; let idx: Int; let action: PaletteAction }
        var out: [Scored] = []
        for (idx, a) in allActions.enumerated() {
            let title = a.title.lowercased()
            let sub = (a.subtitle ?? "").lowercased()
            var s: Int? = nil
            if title.hasPrefix(q) { s = 0 }
            else if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { s = 1 }
            else if title.contains(q) { s = 2 }
            else if sub.contains(q) { s = 3 }
            if let s { out.append(Scored(score: s, idx: idx, action: a)) }
        }
        return out
            .sorted { $0.score == $1.score ? $0.idx < $1.idx : $0.score < $1.score }
            .map(\.action)
    }
}

/// One entry in the palette. `id` is used for SwiftUI diffing and
/// keyboard-selection stability; keep it stable across renders.
/// `action` is `@MainActor` because most palette actions mutate
/// `AppEnvironment` or call `PlayerBridge` methods — both are
/// MainActor-isolated. Swift 6 strict concurrency won't let a
/// non-isolated closure body touch those without this annotation.
private struct PaletteAction: Identifiable {
    let id: String
    let title: String
    var subtitle: String? = nil
    let icon: String
    var shortcut: String? = nil
    let action: @MainActor (AppEnvironment) -> Void

    static func tab(_ title: String, icon: String, tab: AppTab) -> PaletteAction {
        let shortcut: String
        switch tab {
        case .home: shortcut = "⌘1"
        case .explore: shortcut = "⌘2"
        case .search: shortcut = "⌘3"
        case .library: shortcut = "⌘4"
        }
        return PaletteAction(
            id: "tab-\(title.lowercased())",
            title: "Go to \(title)",
            icon: icon,
            shortcut: shortcut,
            action: { $0.activeTab = tab }
        )
    }
}

extension Notification.Name {
    /// Posted by the command palette to ask RiffApp to open the Mini
    /// Player window (which the palette can't do directly because
    /// `@Environment(\.openWindow)` isn't reachable from a sheet
    /// launched off a shortcut).
    static let riffOpenMiniPlayerWindow = Notification.Name("riff.openMiniPlayerWindow")
}

private func shortDate() -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f.string(from: Date())
}
