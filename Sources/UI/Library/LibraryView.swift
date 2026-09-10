import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var section: Section = .liked
    @State private var sort: SortOrder = .recentlyAdded
    @State private var filterText: String = ""
    @State private var items: [MediaItem] = []
    @State private var mixedForYou: [HomeSection] = []
    /// D3 — "New from artists you follow". Bandcamp-inspired
    /// chronological release feed. Only populated when the user is on
    /// the Artists sub-section AND signed-in; otherwise we don't pay
    /// the fan-out cost (up to N parallel /browse calls).
    @State private var followedReleases: [MediaItem] = []
    @State private var followedReleasesLoading: Bool = false
    @State private var errorMessage: String?

    enum Section: String, CaseIterable, Identifiable {
        case liked = "Liked", playlists = "Playlists", albums = "Albums", artists = "Artists", podcasts = "Podcasts", history = "History"
        var id: String { rawValue }
    }

    /// Library sort orders, mirroring YouTube Music's web library
    /// dropdown. The InnerTube response order is "recently added"
    /// (most-recent first), so we treat that as the natural ordering
    /// and sort A-Z / Z-A as local permutations on top of it.
    ///
    /// `playCount` and `lastPlayed` are derived from the local
    /// `PlayerBridge.playedEntries` journal — InnerTube doesn't surface
    /// per-track listening stats on the Liked Songs browse response,
    /// so we count locally. These two orders are only meaningful for
    /// individual songs (i.e. the Liked section) and are hidden in the
    /// menu for other sections.
    enum SortOrder: String, CaseIterable, Identifiable {
        case recentlyAdded = "Recently added"
        case aToZ = "A to Z"
        case zToA = "Z to A"
        case playCount = "Most played"
        case lastPlayed = "Last played"
        var id: String { rawValue }

        /// Sorts that depend on the local play-history journal. They
        /// only make sense for song rows (the Liked section), so the
        /// dropdown filters them out for Playlists / Albums / etc.
        var requiresPlayHistory: Bool {
            switch self {
            case .playCount, .lastPlayed: return true
            case .recentlyAdded, .aToZ, .zToA: return false
            }
        }
    }

    /// Items after applying the search-within-library filter, the
    /// active sort, and the user's pinned-id partition. Computed
    /// property keeps the view declaration tidy and avoids stale state
    /// when the user switches sort/filter without re-fetching.
    ///
    /// Order of operations: filter → sort → float pinned to top.
    /// Pinning is applied LAST so it always wins regardless of the
    /// chosen sort — that's the whole point of pinning. Within the
    /// pinned head and the unpinned tail we still preserve the sort,
    /// so the user's mental model ("Recently added, but my favorites
    /// first") stays intact.
    private var displayedItems: [MediaItem] {
        let filtered: [MediaItem]
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty {
            filtered = items
        } else {
            filtered = items.filter {
                $0.title.lowercased().contains(needle)
                    || $0.subtitle.lowercased().contains(needle)
            }
        }
        let sorted: [MediaItem]
        switch sort {
        case .recentlyAdded:
            sorted = filtered  // server order — newest first
        case .aToZ:
            sorted = filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .zToA:
            sorted = filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .playCount:
            let counts = LibrarySorting.playCounts(from: env.player.playedEntries)
            sorted = filtered.sorted {
                let lhs = counts[$0.id] ?? 0
                let rhs = counts[$1.id] ?? 0
                if lhs == rhs {
                    // Tie-break alphabetically so the order is stable
                    // (otherwise SwiftUI would shuffle equally-played
                    // rows on every play-count tick).
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhs > rhs  // most-played first
            }
        case .lastPlayed:
            let last = LibrarySorting.lastPlayed(from: env.player.playedEntries)
            sorted = filtered.sorted {
                let lhs = last[$0.id] ?? .distantPast
                let rhs = last[$1.id] ?? .distantPast
                if lhs == rhs {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhs > rhs  // most-recent first
            }
        }
        return LibrarySorting.partitionPinned(sorted, pinned: env.pinnedLibraryIds)
    }

    /// Sort orders shown in the dropdown for the current section.
    /// Liked Songs gets the full set (incl. play-count / last-played
    /// derived from local history); other sections get only the
    /// server-order-friendly orders since play counts on a *playlist*
    /// row don't have a meaningful definition here.
    private var availableSorts: [SortOrder] {
        SortOrder.allCases.filter { order in
            !order.requiresPlayHistory || section == .liked
        }
    }

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $env.libraryNavPath) {
            Group {
                if env.isSignedIn {
                    signedInView
                } else {
                    anonymousEmptyState
                }
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
        }
    }

    private var signedInView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented)
            // macOS renders a segmented Picker's label as a leading
            // caption — "Section" was showing up as a phantom first
            // segment. The label stays for VoiceOver; just not drawn.
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.top, 8)

            // Sort + filter row. Mirrors YT Music web's library
            // header: live filter on the left, sort dropdown on the
            // right, hit count in the middle when filtering.
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    TextField("Filter \(section.rawValue.lowercased())", text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())

                if !filterText.isEmpty {
                    Text("\(displayedItems.count) of \(items.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer()

                Menu {
                    ForEach(availableSorts) { order in
                        Button {
                            sort = order
                        } label: {
                            if sort == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(sort.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06))
                    .foregroundStyle(.white.opacity(0.85))
                    .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort library")
            }
            .padding(.horizontal, 24)

            ScrollView {
                // D3 — "New from artists you follow" sits at the top
                // of the Artists sub-section. Bandcamp-inspired
                // chronological release feed sorted year-desc; gated
                // to Artists so the fan-out cost is only paid when
                // the user is actually looking at this sub-section.
                if section == .artists && (!followedReleases.isEmpty || followedReleasesLoading) {
                    followedReleasesRail
                        .padding(.bottom, 16)
                }
                // Personalized "Mixed for you" carousels sit above
                // the section grid so the user sees auto-generated
                // mixes (Supermix, Discover Mix, …) before the
                // explicit library content. Anonymous responses are
                // empty — the section hides itself entirely.
                if !mixedForYou.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(mixedForYou) { section in
                            HomeSectionRow(section: section)
                        }
                    }
                    .padding(.bottom, 16)
                }
                if let errorMessage {
                    ErrorBanner(message: errorMessage) {
                        Task { await load() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
                if items.isEmpty && errorMessage == nil {
                    EmptyState(
                        systemImage: sectionEmptyIcon,
                        title: sectionEmptyTitle,
                        subtitle: sectionEmptySubtitle,
                        cta: sectionEmptyCTA
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else if displayedItems.isEmpty {
                    EmptyState(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "No matches",
                        subtitle: "No \(section.rawValue.lowercased()) match \u{201C}\(filterText)\u{201D}.",
                        cta: EmptyState.CTA("Clear filter", systemImage: "xmark") {
                            filterText = ""
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                        ForEach(displayedItems) { item in
                            ThumbnailButton(item: item, showPinAction: true)
                                .overlay(alignment: .topLeading) {
                                    // Visual cue: tiny pin badge on the
                                    // tile when this item is pinned, so
                                    // the user can spot which tiles are
                                    // floating to the top by choice vs.
                                    // by natural sort order. Off-grid
                                    // when not pinned so unpinned tiles
                                    // are visually unchanged.
                                    if env.isPinned(item.id) {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(5)
                                            .background(Theme.red, in: Circle())
                                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                                            .padding(6)
                                            .help("Pinned — right-click to unpin")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .task(id: section) {
            // Reset filter on section switch — searching for "abc" in
            // Liked then jumping to Albums shouldn't carry the needle
            // forward; the user's intent moved with the section.
            filterText = ""
            // If the active sort is no longer offered in the new
            // section (e.g. user picked "Most played" in Liked then
            // switched to Albums), reset to the default rather than
            // leave the dropdown showing an option that isn't in its
            // menu. Recently-added is always the safe fallback.
            if !availableSorts.contains(sort) {
                sort = .recentlyAdded
            }
            await load()
        }
    }

    private var sectionEmptyIcon: String {
        switch section {
        case .liked:     return "heart"
        case .playlists: return "music.note.list"
        case .albums:    return "square.stack"
        case .artists:   return "person.2"
        case .podcasts:  return "mic"
        case .history:   return "clock.arrow.circlepath"
        }
    }

    private var sectionEmptyTitle: String {
        switch section {
        case .liked:     return "No liked songs yet"
        case .playlists: return "No playlists yet"
        case .albums:    return "No saved albums"
        case .artists:   return "No followed artists"
        case .podcasts:  return "No podcast subscriptions"
        case .history:   return "No listening history yet"
        }
    }

    private var sectionEmptySubtitle: String {
        switch section {
        case .liked:     return "Tap the heart on any song to save it here."
        case .playlists: return "Create one from the current queue, or save one from search."
        case .albums:    return "Open an album, then choose “Save album” from its menu."
        case .artists:   return "Follow an artist and their releases show up here."
        case .podcasts:  return "Subscribe to a podcast to see new episodes here."
        case .history:   return "Start playing something — the last songs you heard show up here."
        }
    }

    private var sectionEmptyCTA: EmptyState.CTA? {
        switch section {
        case .liked, .albums, .artists, .podcasts, .history:
            return EmptyState.CTA("Browse home", systemImage: "house") {
                env.activeTab = .home
            }
        case .playlists:
            return EmptyState.CTA("New playlist", systemImage: "plus") {
                env.isNewPlaylistSheetPresented = true
            }
        }
    }

    private var anonymousEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Sign in to unlock your library")
                .font(.system(size: 22, weight: .semibold))
            Text("Signing in with your Google account brings in your Liked Songs, playlists, and subscriptions — and if you have YouTube Music Premium, removes ads.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Sign In with Google") { env.isSignInSheetPresented = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func load() async {
        // Fan out: library section + Mixed-for-you in parallel. The
        // mixed feed is best-effort — anonymous responses are empty
        // and any failure should silently hide the carousels rather
        // than show an error banner above the user's primary library
        // content.
        async let mixedFetch = env.innerTube.browseMixedForYou()
        if section == .history {
            // History comes from Riff's OWN journal — the same
            // `playedEntries` Home's "You've been playing" renders. The
            // InnerTube history feed was returning empty (it's a
            // separate server-side log that anonymous-shaped sessions
            // never populate), so the tab read "No listening history
            // yet" while Home showed hundreds of plays. Local is also
            // instant and works without a network round-trip.
            // Most-recent first, deduped to the latest play of each id.
            let entries = env.player.playedEntries
            var counts: [String: Int] = [:]
            var lastPlayed: [String: Date] = [:]
            for entry in entries {
                counts[entry.item.id, default: 0] += 1
                lastPlayed[entry.item.id] = max(lastPlayed[entry.item.id] ?? .distantPast, entry.playedAt)
            }
            var seen = Set<String>()
            let now = Date()
            items = entries.reversed().compactMap { entry -> MediaItem? in
                guard seen.insert(entry.item.id).inserted else { return nil }
                let item = entry.item
                // "Artist • 2h ago • 3×" — the journal has the data; the
                // row should say when and how often, not just who.
                let artist = item.subtitle
                    .split(whereSeparator: { $0 == "·" || $0 == "•" })
                    .first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? item.subtitle
                let when = Self.relativeFormatter.localizedString(for: lastPlayed[item.id] ?? entry.playedAt, relativeTo: now)
                let plays = counts[item.id] ?? 1
                let subtitle = [artist, when, plays > 1 ? "\(plays)×" : nil].compactMap { $0 }.joined(separator: " • ")
                return MediaItem(id: item.id, kind: item.kind, title: item.title, subtitle: subtitle,
                                 thumbnailURL: item.thumbnailURL, albumId: item.albumId, artistId: item.artistId,
                                 setVideoId: item.setVideoId, durationSeconds: item.durationSeconds, year: item.year)
            }
            errorMessage = nil
        } else {
            do {
                var fetched = try await env.innerTube.library(section: section)
                guard !Task.isCancelled else { return }
                if fetched.isEmpty, env.isSignedIn {
                    // The WebView rotates Google's session cookies; if
                    // the InnerTube jar fell behind, the library answers
                    // anonymously (empty). Re-bridge and retry once
                    // before believing an empty library.
                    await CookieJar.syncFromWebView()
                    fetched = (try? await env.innerTube.library(section: section)) ?? []
                    guard !Task.isCancelled else { return }
                }
                items = fetched
                errorMessage = nil
                // Silent auth decay: a stale-but-unexpired cookie makes
                // InnerTube answer library calls with an anonymous-shaped
                // EMPTY response instead of an error — the user then sees
                // "No liked songs yet" for a library they know is full.
                // Confirm with a cheap account probe before believing an
                // empty library from a signed-in user.
                if fetched.isEmpty, env.isSignedIn,
                   await env.innerTube.fetchAccountInfo() == nil {
                    errorMessage = "Your YouTube Music session looks expired — sign in again to see your library."
                }
            } catch {
                // A section switch cancels the previous load; its
                // stale catch must not blank the NEW section or show
                // "Network error: cancelled".
                if Task.isCancelled || LoadErrorPresenter.isCancellation(error) { return }
                items = []
                errorMessage = LoadErrorPresenter.message(for: error, env: env)
            }
        }
        // try? collapses both "feed errored" and "feed returned empty"
        // into the same hide-the-carousels code path — exactly what we
        // want for a best-effort secondary surface.
        let mixedRaw = (try? await mixedFetch) ?? []
        guard !Task.isCancelled else { return }
        mixedForYou = mixedRaw.compactMap { sec in
            let kept = sec.items.filter { !env.isBlocked($0) }
            guard !kept.isEmpty else { return nil }
            return HomeSection(id: sec.id, title: sec.title, items: kept)
        }

        // D3 — only fetch the followed-artist feed when the user is
        // viewing Artists. Fan-out is expensive (up to N /browse calls
        // in parallel) and the rail only renders on this section, so
        // we don't pay the cost on every section switch.
        if section == .artists, env.isSignedIn {
            await loadFollowedReleases()
        } else {
            followedReleases = []
        }
    }

    /// D3 — header + horizontal release tiles for the followed-artist
    /// feed. Reuses `ThumbnailButton` so tap/context-menu/hover-play
    /// behavior matches the rest of the Library grid. Renders a 4-tile
    /// shimmer while the parallel fan-out resolves.
    @ViewBuilder
    private var followedReleasesRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New from artists you follow")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("Recent releases, newest first")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 24)

            if followedReleases.isEmpty && followedReleasesLoading {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.06))
                                .frame(width: 180, height: 180)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(followedReleases) { item in
                            ThumbnailButton(item: item)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    /// Refresh the D3 "New from artists you follow" rail. Best-effort:
    /// any failure (network, parser drift, no subscribed artists)
    /// collapses to an empty rail rather than an error banner — the
    /// Artists grid below remains the user's primary surface.
    private func loadFollowedReleases() async {
        followedReleasesLoading = true
        defer { followedReleasesLoading = false }
        let raw = (try? await env.innerTube.newReleasesFromFollowedArtists()) ?? []
        // Mirror the blocked-artist filter we apply elsewhere — if the
        // user has thumbed-down an artist, their releases shouldn't
        // re-surface here through the side door.
        followedReleases = raw.filter { !env.isBlocked($0) }
    }
}
