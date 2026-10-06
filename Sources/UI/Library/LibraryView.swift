import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var section: Section = .liked
    @State private var sort: SortOrder = .recentlyAdded
    @State private var filterText: String = ""
    @State private var items: [MediaItem] = []
    @State private var mixedForYou: [HomeSection] = []
    /// D3 — "New from artists you follow". Bandcamp-inspired
    /// chronological release feed. Only fetched when the user is on
    /// the Artists sub-section AND signed-in; otherwise we don't pay
    /// the fan-out cost (up to N parallel /browse calls). Kept (not
    /// cleared) on other sections so a return to Artists shows the
    /// cached tiles at once; it renders on Artists only.
    @State private var followedReleases: [MediaItem] = []
    @State private var followedReleasesLoading: Bool = false
    /// Cache stamp for the D3 rail: the ids of the artists its last
    /// fan-out scanned (the first `followedReleasesArtistLimit`
    /// followed artists, server order) and when it ran. A return to
    /// Artists with the same scan set inside `followedReleasesTTL`
    /// reuses the tiles instead of re-downloading up to 25 artist
    /// pages. Cleared with the other per-account state on sign-out.
    @State private var followedReleasesKey: [String] = []
    @State private var followedReleasesFetchedAt: Date?
    /// True while a network section's fetch (and its empty-library
    /// session probe) is in flight, so an empty `items` reads as
    /// "loading" rather than "No liked songs yet" until the answer
    /// lands. Starts true: `signedInView`'s `.task` always loads on
    /// appear, so its first frame is a load, not an empty library.
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    /// D3 rail scan width — the same default
    /// `newReleasesFromFollowedArtists` uses.
    private static let followedReleasesArtistLimit = 25
    /// How long a D3 rail stays fresh. After that, a return to Artists
    /// refreshes it — in the background, the cached tiles stay up.
    private static let followedReleasesTTL: TimeInterval = 10 * 60

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
        // LibraryView stays mounted across tab switches, so its
        // per-account state outlives a sign-out. Drop it on the
        // transition to signed-out (deliberate sign-out or a
        // server-side session expiry); the anonymous state is on
        // screen then, so nothing flashes, and the next sign-in starts
        // from empty instead of painting the old account's grid, mixes
        // and releases until its own fetch lands. On the stack itself
        // (not its root) so it fires even with a detail page pushed.
        .onChange(of: env.isSignedIn) { _, signedIn in
            if !signedIn { resetAccountState() }
        }
    }

    /// Clears everything LibraryView holds for the signed-in account.
    /// See the `onChange(of: env.isSignedIn)` in `body`.
    private func resetAccountState() {
        items = []
        mixedForYou = []
        followedReleases = []
        followedReleasesKey = []
        followedReleasesFetchedAt = nil
        followedReleasesLoading = false
        // The next sign-in's first frame is a load (see `isLoading`).
        isLoading = true
        errorMessage = nil
        filterText = ""
        // A DetailView pushed from the old account's library (e.g. one
        // of its private playlists) must not stay stacked over the
        // anonymous root or survive into the next account's session.
        env.libraryNavPath = NavigationPath()
    }

    private var signedInView: some View {
        // One filter → sort → pin pass per body evaluation.
        // `displayedItems` is computed (ICU collation over up to ~2,000
        // paged rows); reading it at each use site below re-ran the
        // whole pass two to three times per body.
        let displayed = displayedItems
        return VStack(alignment: .leading, spacing: 12) {
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
                        .foregroundStyle(Theme.Text.secondary)
                    TextField("Filter \(section.rawValue.lowercased())", text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.Fill.soft)
                .clipShape(Capsule())

                if !filterText.isEmpty {
                    Text("\(displayed.count) of \(items.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Text.secondary)
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
                    .background(Theme.Fill.soft)
                    .foregroundStyle(Theme.Text.secondary)
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
                // Mixes are playlists: shown on the Playlists section
                // only. Above Albums / Artists / Podcasts they read as
                // rows that leaked in from another kind.
                if section == .playlists, !mixedForYou.isEmpty {
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
                    if isLoading {
                        // Still fetching — "No liked songs yet" would
                        // be a claim we can't make until the answer
                        // (and, for an empty one, the session probe)
                        // lands.
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        EmptyState(
                            systemImage: sectionEmptyIcon,
                            title: sectionEmptyTitle,
                            subtitle: sectionEmptySubtitle,
                            cta: sectionEmptyCTA
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                } else if displayed.isEmpty {
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
                        ForEach(displayed) { item in
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
        case .albums:    return "Open an album and tap Save to add it here."
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
        // content. The carousels render on Playlists only, so the feed
        // is fetched only there (it used to fire on every section
        // switch, History included); other sections leave the last
        // carousels untouched for the next Playlists visit.
        let client = env.innerTube
        let wantsMixes = section == .playlists
        async let mixedFetch = Self.fetchMixedForYou(using: client, enabled: wantsMixes)
        // The server-ordered Artists list this load fetched, handed to
        // the D3 rail (nil when this isn't Artists or the fetch failed).
        var followedArtists: [MediaItem]?
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
            // A cancelled network load (the section just left) exits
            // without clearing its flag — the replacement load owns it.
            // History is synchronous, so clear it here or an empty
            // journal would show a spinner instead of its empty state.
            isLoading = false
        } else {
            isLoading = true
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
                if section == .artists { followedArtists = fetched }
                // Silent auth decay: a stale-but-unexpired cookie makes
                // InnerTube answer library calls with an anonymous-shaped
                // EMPTY response instead of an error — the user then sees
                // "No liked songs yet" for a library they know is full.
                // Confirm with a cheap account probe before believing an
                // empty library from a signed-in user. `sessionLiveness`
                // is tri-state: only a definitive anonymous answer
                // (false) means expired; a transport failure (nil) is
                // unknown and falls through to the normal empty state.
                if fetched.isEmpty, env.isSignedIn {
                    let alive = await env.innerTube.sessionLiveness()
                    // A section switch cancels this load mid-probe; the
                    // cancelled request must not land a stale "session
                    // looks expired" banner on the NEW section.
                    guard !Task.isCancelled else { return }
                    if alive == false {
                        errorMessage = "Your YouTube Music session looks expired — sign in again to see your library."
                    }
                }
                isLoading = false
            } catch {
                // A section switch cancels the previous load; its
                // stale catch must not blank the NEW section or show
                // "Network error: cancelled".
                if Task.isCancelled || LoadErrorPresenter.isCancellation(error) { return }
                items = []
                errorMessage = LoadErrorPresenter.message(for: error, env: env)
                isLoading = false
            }
        }
        let mixedRaw = await mixedFetch
        guard !Task.isCancelled else { return }
        if let mixedRaw {
            mixedForYou = mixedRaw.compactMap { sec in
                let kept = sec.items.filter { !env.isBlocked($0) }
                guard !kept.isEmpty else { return nil }
                return HomeSection(id: sec.id, title: sec.title, items: kept)
            }
        }

        // D3 — only refresh the followed-artist feed when the user is
        // viewing Artists. Fan-out is expensive (up to N /browse calls
        // in parallel) and the rail only renders on this section, so
        // we don't pay the cost on every section switch. The rail is
        // not cleared elsewhere: it stays cached for the next visit.
        // If the Artists list itself failed, keep whatever rail we had
        // (the error banner covers the failure; Retry reloads).
        if section == .artists, env.isSignedIn, let followedArtists {
            await loadFollowedReleases(followedArtists: followedArtists)
        }
    }

    /// "Mixed for you" renders on the Playlists section only, so it is
    /// fetched only there. nil = not requested (keep the carousels from
    /// the last Playlists visit); [] = the feed failed or came back
    /// empty. `try?` collapses both into the same hide-the-carousels
    /// path — exactly what we want for a best-effort secondary surface.
    nonisolated private static func fetchMixedForYou(using client: InnerTubeClient, enabled: Bool) async -> [HomeSection]? {
        guard enabled else { return nil }
        return (try? await client.browseMixedForYou()) ?? []
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
                    .foregroundStyle(Theme.Text.secondary)
            }
            .padding(.horizontal, 24)

            if followedReleases.isEmpty && followedReleasesLoading {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Theme.Radius.tile)
                                .fill(Theme.Fill.soft)
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
    ///
    /// Cached for the session: the fan-out (up to 25 artist pages)
    /// re-runs only when the scanned artist set changes or the rail is
    /// older than `followedReleasesTTL`. `followedArtists` is the
    /// Artists list `load()` already fetched, in server order — never
    /// the sorted / filtered / pinned `displayedItems`, which would
    /// change which artists get scanned.
    private func loadFollowedReleases(followedArtists: [MediaItem]) async {
        let key = followedArtists.filter { $0.kind == .artist }
            .prefix(Self.followedReleasesArtistLimit)
            .map(\.id)
        guard !key.isEmpty else {
            // No followed artists: nothing to scan, skip the network.
            followedReleases = []
            followedReleasesKey = []
            followedReleasesFetchedAt = nil
            return
        }
        if key == followedReleasesKey, let fetchedAt = followedReleasesFetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.followedReleasesTTL {
            // Fresh rail for the same artists — reuse it. Re-apply the
            // block filter: the user may have blocked an artist since.
            followedReleases = followedReleases.filter { !env.isBlocked($0) }
            return
        }
        followedReleasesLoading = true
        defer { followedReleasesLoading = false }
        let raw = (try? await env.innerTube.newReleasesFromFollowedArtists(limit: Self.followedReleasesArtistLimit)) ?? []
        // A section switch cancels the fan-out mid-flight; its partial
        // result must neither replace the rail nor seed the cache.
        guard !Task.isCancelled else { return }
        // Mirror the blocked-artist filter we apply elsewhere — if the
        // user has thumbed-down an artist, their releases shouldn't
        // re-surface here through the side door.
        followedReleases = raw.filter { !env.isBlocked($0) }
        // Cache only a non-empty rail. Every per-artist failure is
        // swallowed to [], so an empty result for a non-empty artist
        // set is almost always transient — let the next visit retry.
        if raw.isEmpty {
            followedReleasesKey = []
            followedReleasesFetchedAt = nil
        } else {
            followedReleasesKey = key
            followedReleasesFetchedAt = Date()
        }
    }
}
