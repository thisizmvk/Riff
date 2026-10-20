import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sections: [HomeSection] = []
    @State private var signInNudgeDismissed = false
    /// Artist portraits resolved for the "Your top artists" shelf
    /// (artistId → image URL), so the circles show the artist rather
    /// than a recent album cover. Persisted across launches.
    @State private var portraits: [String: URL] = HomeView.loadPortraitCache()
    @State private var chips: [InnerTubeClient.HomeChip] = []
    /// The chip currently filtering Home. `nil` means the default "All"
    /// state — every chip pill renders unselected and the rails are the
    /// untruncated FEmusic_home feed.
    @State private var activeChip: InnerTubeClient.HomeChip?
    /// True while a chip filter fetch is in flight. Drives a light dim on
    /// the rails so a tap reads as "working" even before the feed swaps.
    @State private var chipLoading = false
    @State private var loading = true
    @State private var errorMessage: String?
    /// One-shot guard: once a fetch has succeeded, popping back to
    /// Home doesn't re-run the full browse-home fetch (the `.task`
    /// modifier restarts on every re-appearance because the ScrollView
    /// is the NavigationStack root). Explicit refreshes (sign-in flip,
    /// error-banner retry) bypass it via `load(force: true)`.
    @State private var didInitialLoad = false

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $env.homeNavPath) {
          ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    // Scroll anchor: switching mood chips jumps back here
                    // so the re-scoped feed is seen from the top.
                    Color.clear.frame(height: 0).id("home-top")
                    if let errorMessage {
                        ErrorBanner(message: errorMessage) {
                            Task { await load(force: true) }
                        }
                    }
                    // Anonymous sessions get YouTube's tiny generic feed;
                    // say why, with the one action that fixes it.
                    if !env.isSignedIn, !signInNudgeDismissed {
                        SignInNudgeCard(onDismiss: { signInNudgeDismissed = true })
                    }
                    if !chips.isEmpty {
                        MoodChipRow(
                            chips: chips,
                            activeChip: activeChip,
                            onSelect: { chip in
                                Task { await applyChip(chip) }
                            }
                        )
                    }
                    if loading && sections.isEmpty {
                        HomeSkeleton()
                    } else if let activeChip {
                        // A mood chip is active → the whole feed IS that
                        // mood. Personalized shelves + Blend are hidden so
                        // the filter visibly transforms the page (leaving
                        // them on top made the chip feel like it did
                        // nothing). An empty filtered result says so
                        // rather than silently falling back.
                        if sections.isEmpty {
                            EmptyState(
                                systemImage: "line.3.horizontal.decrease.circle",
                                title: "No \(activeChip.label) rails right now",
                                subtitle: "YouTube didn't return a feed for this mood. Try another, or clear the filter.",
                                cta: EmptyState.CTA("Clear filter", systemImage: "xmark") {
                                    Task { await applyChip(activeChip) }
                                }
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            ForEach(sections) { section in
                                HomeSectionRow(section: section)
                            }
                            .opacity(chipLoading ? 0.55 : 1)
                            .animation(.easeOut(duration: 0.15), value: chipLoading)
                        }
                    } else {
                        // Riff Blend — the signature entry point, above
                        // everything else so a returning listener's first
                        // move can be one tap into a personal mix. Hidden
                        // until there's enough history to blend.
                        if BlendBuilder.isAvailable(from: env.player.playedEntries) {
                            BlendHeroCard()
                        }
                        // Personalized shelves — derived purely from
                        // local play history (no network). Rendered
                        // above browse-home so the user's own listening
                        // is the first thing they see when they return
                        // to the app. Empty until the user has played
                        // ~1 track; below-the-fold sections still show.
                        ForEach(personalizedShelves) { section in
                            HomeSectionRow(section: section)
                        }
                        ForEach(sections) { section in
                            HomeSectionRow(section: section)
                        }
                        .opacity(chipLoading ? 0.55 : 1)
                        .animation(.easeOut(duration: 0.15), value: chipLoading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            .navigationDestination(for: HomeSection.self) { SectionGridView(section: $0) }
            .task { await load() }
            // Resolve portraits for top artists we haven't seen yet (one
            // /browse per new artist, sequential, cached to disk).
            .task(id: topArtistIdsKey) { await loadPortraits() }
            // Signed-in state flipped (sign-in, or the liveness probe
            // marked the session dead) → the feed shape changes wholesale;
            // refetch instead of leaving the old feed on screen.
            .onChange(of: env.isSignedIn) { _, _ in Task { await load(force: true) } }
            // Re-scoping by mood chip → jump to the top so the new feed
            // isn't hidden below the fold where the last one was scrolled.
            .onChange(of: activeChip) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("home-top", anchor: .top)
                }
            }
          }
        }
    }

    /// Reads directly off the live played-history journal — no
    /// caching, no debouncing. Recomputes every render because the
    /// underlying arithmetic is cheap (a couple of dictionary passes
    /// over ~500 entries), and this way a track that lands mid-view
    /// updates the shelf without a manual refresh.
    ///
    /// Blocked artists are filtered out of the top-artists list so
    /// unfollowing someone via the context menu instantly hides
    /// their tile too.
    private var personalizedShelves: [HomeSection] {
        var out: [HomeSection] = []
        let entries = env.player.playedEntries
        let topArtists = PersonalizedShelves.topArtists(from: entries)
            .filter { !env.isBlocked(artistId: $0.id) }
            .map { item -> MediaItem in
                guard let portrait = portraits[item.id] else { return item }
                return item.withThumbnail(portrait)
            }
        if !topArtists.isEmpty {
            out.append(HomeSection(
                id: "personal.topArtists",
                title: "Your top artists this month",
                items: topArtists
            ))
        }
        let topTracks = PersonalizedShelves.topTracks(from: entries)
            .filter { entry in
                guard let artistId = entry.artistId else { return true }
                return !env.isBlocked(artistId: artistId)
            }
        if !topTracks.isEmpty {
            out.append(HomeSection(
                id: "personal.topTracks",
                title: "You've been playing",
                items: topTracks
            ))
        }
        // Time-aware shelf: what you tend to play at this hour. Purely
        // local, from the journal — no network — and only once the
        // current slot has enough plays to mean something.
        if let shelf = PersonalizedShelves.timeOfDayShelf(from: entries) {
            let kept = shelf.items.filter { item in
                guard let artistId = item.artistId else { return true }
                return !env.isBlocked(artistId: artistId)
            }
            if kept.count >= 4 {
                out.append(HomeSection(id: "personal.timeOfDay." + shelf.slot.rawValue, title: shelf.title, items: kept))
            }
        }
        return out
    }

    private var topArtistIdsKey: String {
        PersonalizedShelves.topArtists(from: env.player.playedEntries).map(\.id).joined(separator: ",")
    }

    private static let portraitCacheKey = "home.artistPortraits"
    private static func loadPortraitCache() -> [String: URL] {
        guard let raw = UserDefaults.standard.dictionary(forKey: portraitCacheKey) as? [String: String] else { return [:] }
        return raw.compactMapValues(URL.init(string:))
    }

    private func loadPortraits() async {
        let missing = PersonalizedShelves.topArtists(from: env.player.playedEntries)
            .map(\.id)
            .filter { portraits[$0] == nil && $0.hasPrefix("UC") }
        guard !missing.isEmpty else { return }
        for id in missing {
            guard let page = try? await env.innerTube.detail(forBrowseId: id),
                  let url = page.artworkURL else { continue }
            portraits[id] = url
        }
        let raw = portraits.mapValues(\.absoluteString)
        UserDefaults.standard.set(raw, forKey: Self.portraitCacheKey)
    }

    /// `force` bypasses the one-shot re-appearance guard AND resets any
    /// active mood-chip filter — used when the feed changes wholesale
    /// (account flip) or the user explicitly retries from the banner.
    private func load(force: Bool = false) async {
        // Pop-back re-runs `.task`; if we've already fetched
        // successfully and have content on screen, skip the refetch
        // entirely instead of re-issuing the browse-home request (and
        // clobbering an active chip filter) on every navigation pop.
        if !force, didInitialLoad, !sections.isEmpty { return }
        // Cache-first render: paint the last successful feed
        // instantly, then fetch fresh in parallel. `loading` only
        // flips true when we have NOTHING to paint (cold cache),
        // so the skeleton disappears from repeat visits.
        if sections.isEmpty, let cached = HomeFeedCache.load() {
            chips = cached.chips
            sections = Self.filterBlocked(cached.sections, env: env)
            loading = false
        } else if sections.isEmpty {
            loading = true
        }
        defer { loading = false }
        do {
            let feed = try await env.innerTube.browseHome()
            // A cancelled load can surface as a truncated "success"
            // (cancellation during a continuation) — never commit it
            // to state or the on-disk cache.
            guard !Task.isCancelled else { return }
            chips = feed.chips
            // Read `activeChip` AFTER the await: if a chip filter
            // landed while this fetch was in flight (or was already
            // active on a non-forced refresh), keep the chip-scoped
            // sections instead of silently reverting to the
            // unfiltered feed.
            if force || activeChip == nil {
                // Filter blocked artists out of every carousel. We drop
                // empty sections too so a section that only contained
                // blocked artists doesn't render as a titled void.
                sections = Self.filterBlocked(feed.sections, env: env)
                activeChip = nil
            }
            errorMessage = nil
            didInitialLoad = true
            // Persist the un-filtered feed to disk — blocked
            // artists is a live preference that can change; we
            // want the cache to hold the raw response and re-filter
            // on read.
            HomeFeedCache.save(
                .init(chips: feed.chips, sections: feed.sections, savedAt: Date())
            )
        } catch {
            // A push cancels the `.task`-scoped load; that's not an
            // error the user should see ("Network error: cancelled").
            if Task.isCancelled || LoadErrorPresenter.isCancellation(error) { return }
            errorMessage = LoadErrorPresenter.message(for: error, env: env)
            // Keep stale sections visible (if any) so the user can still
            // interact with them while the banner indicates the failure.
        }
    }

    /// Swap the rails to a chip-scoped feed (or back to the default
    /// "All" state when the user taps the active chip again). We don't
    /// re-fetch the chip list itself — chips are stable across filter
    /// changes and a second fetch would just blink the row.
    private func applyChip(_ chip: InnerTubeClient.HomeChip) async {
        let previous = activeChip
        let clearing = (activeChip == chip)
        // Optimistic selection — flip the pill's state on the tap itself,
        // not after the network returns. Without this the chip looked
        // dead for the whole fetch ("mood buttons look unresponsive").
        // Rolled back below if the fetch fails.
        activeChip = clearing ? nil : chip
        chipLoading = true
        defer { chipLoading = false }
        do {
            let raw: [HomeSection]
            if clearing {
                // Tap the active chip again to clear the filter.
                raw = try await env.innerTube.browseHome().sections
            } else {
                raw = try await env.innerTube.browseHomeFiltered(chipParams: chip.params)
            }
            guard !Task.isCancelled else { return }
            sections = Self.filterBlocked(raw, env: env)
            errorMessage = nil
        } catch {
            if Task.isCancelled || LoadErrorPresenter.isCancellation(error) { return }
            // Undo the optimistic selection so the pills match the feed.
            activeChip = previous
            errorMessage = LoadErrorPresenter.message(for: error, env: env)
        }
    }

    @MainActor
    private static func filterBlocked(_ raw: [HomeSection], env: AppEnvironment) -> [HomeSection] {
        raw.compactMap { sec in
            let kept = sec.items.filter { !env.isBlocked($0) }
            guard !kept.isEmpty else { return nil }
            return HomeSection(id: sec.id, title: sec.title, items: kept)
        }
    }
}

/// Horizontal scrolling row of mood / activity chips above the Home
/// rails. Mirrors YT Music iOS's "Energize · Workout · Focus · Sleep"
/// strip — single tap re-scopes Home, second tap on the active chip
/// clears the filter. Active chip uses Theme.red as the fill so it
/// reads as a deliberate selection rather than just a hover state.
private struct MoodChipRow: View {
    let chips: [InnerTubeClient.HomeChip]
    let activeChip: InnerTubeClient.HomeChip?
    let onSelect: (InnerTubeClient.HomeChip) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    MoodChipPill(
                        label: chip.label,
                        isActive: chip == activeChip,
                        action: { onSelect(chip) }
                    )
                }
            }
        }
        .scrollClipDisabled()
    }
}

private struct MoodChipPill: View {
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Theme.Selected.text : Theme.Text.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isActive
                              ? Theme.red
                              : Color.white.opacity(hovering ? 0.12 : 0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isActive ? Color.clear : Theme.Fill.strong,
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isActive ? "Tap to clear filter" : "Filter Home by \(label)")
    }
}

struct HomeSection: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let items: [MediaItem]
}

/// Skeleton rows shown while `browseHome()` is in flight. Two carousels'
/// worth of placeholder tiles with a soft pulse, so an empty Home tab
/// reads as "loading" instead of "broken".
private struct HomeSkeleton: View {
    @State private var pulse = false
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: Theme.Radius.thumb)
                        .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                        .frame(width: 180, height: 22)
                    HStack(spacing: 16) {
                        ForEach(0..<5, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: Theme.Radius.tile)
                                    .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                                    .frame(width: 180, height: 180)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                                    .frame(width: 140, height: 12)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                                    .frame(width: 100, height: 10)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

struct HomeSectionRow: View {
    let section: HomeSection

    /// "Quick picks" rails on YT Music iOS are dense 2-column grids
    /// (4 rows × 2 cols of small list rows) rather than wide tile carousels.
    /// We detect by title and render accordingly.
    private var renderAsQuickPicks: Bool {
        let lower = section.title.lowercased()
        return lower.contains("quick picks") || lower == "quick picks"
    }

    @Environment(AppEnvironment.self) private var env
    @State private var pageStart = 0
    /// Keyboard focus by tile key: ←/→ move focus (and scroll to it).
    @FocusState private var focusedTile: String?
    private static let pageSize = 4

    private func tileKey(_ idx: Int) -> String { "\(section.id)#\(idx)" }

    var body: some View {
        // ScrollViewReader wraps the WHOLE row so the header chevrons
        // (YT Music web puts paging in the section header, not hover
        // overlays) can drive the carousel's scroll position.
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 10) {
                    Text(section.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    if !renderAsQuickPicks, section.items.count > Self.pageSize {
                        Button {
                            env.navigate(toSection: section)
                        } label: {
                            Text("More")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().strokeBorder(Theme.Fill.strong, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Show all of \(section.title)")
                        headerChevron("chevron.left", help: "Previous tiles",
                                      disabled: pageStart <= 0) { page(-1, proxy) }
                        headerChevron("chevron.right", help: "More tiles",
                                      disabled: pageStart + Self.pageSize >= section.items.count) { page(+1, proxy) }
                    }
                }

                if renderAsQuickPicks {
                    quickPicksGrid
                } else {
                    carousel(proxy)
                }
            }
        }
    }

    private func carousel(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16) {
                ForEach(Array(section.items.enumerated()), id: \.offset) { idx, item in
                    ThumbnailButton(item: item, externalFocus: $focusedTile, focusKey: tileKey(idx))
                        .id(tileKey(idx))
                }
            }
        }
        // Arrow keys move tile focus once a tile in this row has
        // keyboard focus (Tab into it), scrolling to keep it visible.
        .onKeyPress(.rightArrow) { moveFocus(+1, proxy); return .handled }
        .onKeyPress(.leftArrow) { moveFocus(-1, proxy); return .handled }
    }

    /// Always-visible outlined paging circle in the section header —
    /// YT Music web's pattern. Disabled (dimmed, inert) at the ends so
    /// the pair also communicates where you are in the rail.
    private func headerChevron(_ symbol: String, help: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(disabled ? 0.3 : 1))
                .frame(width: 30, height: 30)
                .background(Circle().strokeBorder(Theme.Fill.strong, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private func page(_ direction: Int, _ proxy: ScrollViewProxy) {
        let last = max(0, section.items.count - 1)
        pageStart = min(max(pageStart + direction * Self.pageSize, 0), last)
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(tileKey(pageStart), anchor: .leading)
        }
    }

    private func moveFocus(_ direction: Int, _ proxy: ScrollViewProxy) {
        let current = focusedTile.flatMap { key -> Int? in
            guard let hash = key.lastIndex(of: "#") else { return nil }
            return Int(key[key.index(after: hash)...])
        } ?? pageStart
        let next = min(max(current + direction, 0), max(0, section.items.count - 1))
        focusedTile = tileKey(next)
        pageStart = next
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(tileKey(next), anchor: .center)
        }
    }

    /// Compact 2-column list rows — the "Quick picks" pattern from YT
    /// Music iOS. Shows up to 8 items in a 2×4 layout with thumbnails on
    /// the left and title/subtitle to the right.
    private var quickPicksGrid: some View {
        let items = Array(section.items.prefix(8))
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 16),
                      GridItem(.flexible(), spacing: 16)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(items) { item in
                QuickPickRow(item: item)
            }
        }
    }
}

/// Single row inside a Quick Picks grid — small thumbnail + title /
/// subtitle, hover-to-play button overlay on the artwork.
private struct QuickPickRow: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem
    @State private var hovering: Bool = false

    var body: some View {
        Button {
            Task { await play() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    AsyncImage(url: item.thumbnailURL?.upscaledArtwork(to: 120)) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Theme.Fill.soft
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb))
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.5)
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.white.opacity(hovering ? 0.06 : 0.0))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func play() async {
        switch item.kind {
        case .song, .episode: await env.player.play(item: item)
        case .album:          await env.player.playAlbum(id: item.id)
        case .playlist:       await env.player.playPlaylist(id: item.id)
        case .artist:         await env.player.playArtistRadio(id: item.id)
        case .podcast:        await env.player.playPodcast(id: item.id)
        }
    }
}


private extension MediaItem {
    /// Same item with a different artwork URL (fields are `let`).
    func withThumbnail(_ url: URL) -> MediaItem {
        MediaItem(id: id, kind: kind, title: title, subtitle: subtitle, thumbnailURL: url,
                  albumId: albumId, artistId: artistId, setVideoId: setVideoId,
                  durationSeconds: durationSeconds, year: year)
    }
}

/// Compact Home card explaining the anonymous feed, with the fix.
private struct SignInNudgeCard: View {
    @Environment(AppEnvironment.self) private var env
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 22))
                .foregroundStyle(Theme.red)
            VStack(alignment: .leading, spacing: 3) {
                Text("You're browsing without an account")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Sign in to get your mixes, listen-again shelves, library and ad-free playback.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Sign In") { env.isSignInSheetPresented = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Dismiss for this session")
            .accessibilityLabel("Dismiss sign-in suggestion")
        }
        .padding(14)
        .background(Theme.Fill.soft)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile).strokeBorder(Theme.Fill.medium, lineWidth: 1))
    }
}

/// "Riff Blend" entry point — the app's signature experimental feature.
/// A single hero card that, on tap, builds a recency-weighted personal
/// mix from the local play-history journal (`BlendBuilder`) and plays
/// it. Each tap reshuffles, so the card is a renewable "play me
/// something I'll like" button that owes nothing to the network.
///
/// Rendered only when `BlendBuilder.isAvailable` — a thin history has
/// nothing to blend, and the ranked shelves already cover that case.
struct BlendHeroCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var building = false

    var body: some View {
        let covers = BlendBuilder.previewArtwork(from: env.player.playedEntries, limit: 4)
        Button(action: play) {
            HStack(spacing: 16) {
                collage(covers)
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .bold))
                        Text("EXPERIMENTAL")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.2)
                    }
                    .foregroundStyle(.white.opacity(0.85))

                    Text("Riff Blend")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(.white)
                    Text("A fresh mix from what you've been playing")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)

                ZStack {
                    Circle().fill(.white)
                        .frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                    if building {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: 1)
                    }
                }
                .padding(.trailing, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Signature "mix" gradient — warm red into deep indigo,
                // the one place in the app that leans chromatic rather
                // than graphite, so the feature reads as special.
                LinearGradient(
                    colors: [Theme.red, Color(red: 0.42, green: 0.16, blue: 0.62)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
            .shadow(color: Theme.red.opacity(0.25), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(building)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Riff Blend, experimental personal mix")
        .accessibilityHint("Plays a fresh shuffle built from your recent listening")
        .accessibilityAddTraits(.isButton)
    }

    /// 2×2 artwork collage behind a darkening scrim so the foreground
    /// text stays legible. Falls back to a flat scrim when there aren't
    /// four distinct covers yet.
    @ViewBuilder
    private func collage(_ covers: [URL]) -> some View {
        ZStack {
            Color.black.opacity(0.25)
            if covers.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { cover(covers[0]); cover(covers[1]) }
                    HStack(spacing: 0) { cover(covers[2]); cover(covers[3]) }
                }
                .opacity(0.9)
            } else if let first = covers.first {
                cover(first)
            }
            // Inner highlight so the collage reads as a raised tile.
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private func cover(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            if case .success(let img) = phase {
                img.resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .frame(width: 46, height: 46)
        .clipped()
    }

    private func play() {
        guard !building else { return }
        building = true
        let mix = BlendBuilder.build(from: env.player.playedEntries)
        guard !mix.isEmpty else {
            building = false
            env.showToast("Not enough history to blend yet.")
            return
        }
        Task {
            await env.player.playTracks(mix)
            building = false
            env.showToast("Riff Blend — \(mix.count) songs")
        }
    }
}
