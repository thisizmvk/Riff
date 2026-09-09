import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sections: [HomeSection] = []
    @State private var chips: [InnerTubeClient.HomeChip] = []
    /// The chip currently filtering Home. `nil` means the default "All"
    /// state — every chip pill renders unselected and the rails are the
    /// untruncated FEmusic_home feed.
    @State private var activeChip: InnerTubeClient.HomeChip?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $env.homeNavPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    if let errorMessage {
                        ErrorBanner(message: errorMessage) {
                            Task { await load() }
                        }
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
                    } else {
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
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            .task { await load() }
            // Signed-in state flipped (sign-in, or the liveness probe
            // marked the session dead) → the feed shape changes wholesale;
            // refetch instead of leaving the old feed on screen.
            .onChange(of: env.isSignedIn) { _, _ in Task { await load() } }
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
        return out
    }

    private func load() async {
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
            chips = feed.chips
            // Filter blocked artists out of every carousel. We drop
            // empty sections too so a section that only contained
            // blocked artists doesn't render as a titled void.
            sections = Self.filterBlocked(feed.sections, env: env)
            activeChip = nil
            errorMessage = nil
            // Persist the un-filtered feed to disk — blocked
            // artists is a live preference that can change; we
            // want the cache to hold the raw response and re-filter
            // on read.
            HomeFeedCache.save(
                .init(chips: feed.chips, sections: feed.sections, savedAt: Date())
            )
        } catch {
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
        if activeChip == chip {
            // Tap the active chip again to clear the filter.
            do {
                let feed = try await env.innerTube.browseHome()
                sections = Self.filterBlocked(feed.sections, env: env)
                activeChip = nil
                errorMessage = nil
            } catch {
                errorMessage = LoadErrorPresenter.message(for: error, env: env)
            }
            return
        }
        do {
            let raw = try await env.innerTube.browseHomeFiltered(chipParams: chip.params)
            sections = Self.filterBlocked(raw, env: env)
            activeChip = chip
            errorMessage = nil
        } catch {
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
                .foregroundStyle(isActive ? Color.black : .white)
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
                            isActive ? Color.clear : Color.white.opacity(0.12),
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
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                        .frame(width: 180, height: 22)
                    HStack(spacing: 16) {
                        ForEach(0..<5, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 12)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            if renderAsQuickPicks {
                quickPicksGrid
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(section.items) { item in
                            ThumbnailButton(item: item)
                        }
                    }
                }
            }
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
                    AsyncImage(url: item.thumbnailURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.06)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.5)
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.white.opacity(hovering ? 0.06 : 0.0))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
