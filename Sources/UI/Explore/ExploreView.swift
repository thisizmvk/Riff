import SwiftUI

/// Explore tab — Charts, New releases, Featured playlists, etc.
/// The response shape from `FEmusic_explore` is identical to the
/// Home feed (musicCarouselShelfRenderer-based shelves), so we
/// reuse `HomeSection` + `HomeSectionRow` rather than parallel
/// types. A second fetch pulls the Moods & Genres tile grid and
/// appends it under its own heading.
struct ExploreView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sections: [HomeSection] = []
    @State private var moods: [InnerTubeClient.MoodShelf] = []
    @State private var loading = true
    @State private var errorMessage: String?

    /// The four YT-Music-web category buttons, mapped onto whichever
    /// shelves this Explore response actually contains. Each scrolls to
    /// its section; categories with no matching shelf are hidden.
    private var categoryTargets: [(icon: String, label: String, id: String)] {
        var out: [(String, String, String)] = []
        func firstSection(containing words: [String]) -> HomeSection? {
            sections.first { s in
                let t = s.title.lowercased()
                return words.contains { t.contains($0) }
            }
        }
        if let s = firstSection(containing: ["new release", "new albums", "new singles"]) {
            out.append(("sparkles", "New releases", s.id))
        }
        if let s = firstSection(containing: ["chart", "top song", "trending", "biggest"]) {
            out.append(("chart.line.uptrend.xyaxis", "Charts", s.id))
        }
        if let firstMood = moods.first {
            out.append(("theatermasks.fill", "Moods & genres", firstMood.id))
        }
        if let s = firstSection(containing: ["podcast", "episode"]) {
            out.append(("mic.fill", "Podcasts", s.id))
        }
        // Fall back to the first few shelves when nothing matched, so the
        // bar never renders empty on an unexpected feed shape.
        if out.isEmpty {
            out = sections.prefix(4).compactMap { s in
                let t = s.title.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : ("music.note", t, s.id)
            }
        }
        return out
    }

    /// All-songs shelves ("Top songs", "Trending") render as a numbered
    /// multi-column chart list — YT Music web's Charts treatment —
    /// instead of a tile carousel.
    private func isChartShelf(_ section: HomeSection) -> Bool {
        section.items.count >= 5 && section.items.allSatisfy { $0.kind == .song }
    }

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $env.exploreNavPath) {
          ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    ExploreHeader()
                        .padding(.bottom, 4)
                        .id("explore-top")
                    if let errorMessage {
                        ErrorBanner(message: errorMessage) {
                            Task { await load() }
                        }
                    }
                    if loading && sections.isEmpty {
                        ExploreSkeleton()
                    } else {
                        // YT Music web's four big category buttons.
                        // Scroll-jump to the matching shelf.
                        if !categoryTargets.isEmpty {
                            ExploreCategoryBar(targets: categoryTargets) { id in
                                withAnimation(.easeOut(duration: 0.3)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        ForEach(sections) { section in
                            if isChartShelf(section) {
                                ChartListSection(section: section)
                                    .id(section.id)
                            } else {
                                HomeSectionRow(section: section)
                                    .id(section.id)
                            }
                        }
                        // Moods & genres as YT-Music-style colorful tiles
                        // (a solid hue per entry with a tilted artwork
                        // corner), not plain carousels.
                        ForEach(moods) { shelf in
                            MoodGenreSection(shelf: shelf)
                                .id(shelf.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            .navigationDestination(for: HomeSection.self) { SectionGridView(section: $0) }
            .navigationDestination(for: InnerTubeClient.MoodCategory.self) { MoodCategoryView(category: $0) }
            .task { await load() }
          }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let exploreRaw = env.innerTube.browseExplore()
        async let moodsRaw = env.innerTube.browseMoodsAndGenres()
        do {
            let (ex, mg) = try await (exploreRaw, moodsRaw)
            sections = ex.compactMap { sec in
                let kept = sec.items.filter { !env.isBlocked($0) }
                guard !kept.isEmpty else { return nil }
                return HomeSection(id: sec.id, title: sec.title, items: kept,
                                   moreBrowseId: sec.moreBrowseId, moreParams: sec.moreParams)
            }
            // Category buttons, not artist tiles — nothing to block.
            moods = mg
            errorMessage = nil
        } catch {
            if Task.isCancelled || LoadErrorPresenter.isCancellation(error) { return }
            errorMessage = LoadErrorPresenter.message(for: error, env: env)
        }
    }
}

private struct ExploreHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Explore")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text("Charts, new releases, and moods worth a listen.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// YT Music web's four large category buttons — icon + label on a
/// soft card, one per category, equal widths. Pure navigation: each
/// scroll-jumps to its shelf.
private struct ExploreCategoryBar: View {
    let targets: [(icon: String, label: String, id: String)]
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(targets, id: \.id) { target in
                Button { onPick(target.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: target.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.red)
                        Text(target.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.Fill.strong, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help("Jump to \(target.label)")
            }
        }
    }
}

/// Numbered multi-column chart list for all-song shelves — YT Music
/// web's "Top songs" treatment: rank, artwork, title + artists,
/// duration, flowing into as many ~360pt columns as fit.
private struct ChartListSection: View {
    let section: HomeSection

    private let columns = [GridItem(.adaptive(minimum: 330, maximum: 480), spacing: 28)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                ForEach(Array(section.items.enumerated()), id: \.offset) { idx, item in
                    ChartRow(rank: idx + 1, item: item)
                }
            }
        }
    }
}

private struct ChartRow: View {
    @Environment(AppEnvironment.self) private var env
    let rank: Int
    let item: MediaItem
    @State private var hovering = false

    private var isCurrent: Bool { env.player.currentTrack?.videoId == item.id }

    var body: some View {
        Button {
            Task { await env.player.play(item: item) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Text("\(rank)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Text.secondary)
                        .opacity(hovering ? 0 : 1)
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(hovering ? 1 : 0)
                }
                .frame(width: 26)
                AsyncImage(url: item.thumbnailURL?.upscaledArtwork(to: 120)) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.Fill.soft
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.red : .white)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        ArtistLinkLine(
                            subtitle: item.subtitle,
                            primaryArtistId: item.artistId,
                            fontSize: 12,
                            baseOpacity: 0.55
                        )
                    }
                }
                Spacer(minLength: 8)
                if let secs = item.durationSeconds {
                    Text(String(format: "%d:%02d", secs / 60, secs % 60))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Theme.Fill.soft : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu { TrackContextMenu(item: item) }
        .help("Play \(item.title)")
    }
}

/// One Moods & Genres shelf ("Moods & moments" / "Genres") rendered
/// as YT Music web's category buttons: a dark pill with the category's
/// OWN color (served by YT as leftStripeColor) as a left stripe.
/// Tapping opens the category's curated-playlist page.
private struct MoodGenreSection: View {
    let shelf: InnerTubeClient.MoodShelf

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !shelf.title.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(shelf.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(shelf.categories) { category in
                    MoodTile(category: category)
                }
            }
        }
    }
}

private struct MoodTile: View {
    let category: InnerTubeClient.MoodCategory
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: category) {
            HStack(spacing: 0) {
                // YT's category color as the left stripe — the
                // signature of its moods grid.
                Rectangle()
                    .fill(Color(argb: category.colorARGB))
                    .frame(width: 5)
                Text(category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
            .frame(height: 48)
            .background(hovering ? Theme.Fill.medium : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Fill.strong, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Open \(category.title)")
        .accessibilityLabel("\(category.title) category")
    }
}

private struct ExploreSkeleton: View {
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
