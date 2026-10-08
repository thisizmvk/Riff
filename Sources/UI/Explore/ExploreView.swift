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
    @State private var moods: [HomeSection] = []
    @State private var loading = true
    @State private var errorMessage: String?

    /// Chips for the section-jump bar: each top-level Explore shelf, plus
    /// a single "Moods & genres" chip anchored to the first mood shelf.
    /// Empty titles (some shelves arrive untitled) are dropped.
    private var jumpTargets: [(id: String, label: String)] {
        var t = sections
            .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (id: $0.id, label: $0.title) }
        if let firstMood = moods.first {
            t.append((id: firstMood.id, label: "Moods & genres"))
        }
        return t
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
                        // Quick-jump bar: a long Explore page (charts, new
                        // releases, videos, moods) is a lot of scrolling;
                        // these pills scroll straight to a section.
                        if !jumpTargets.isEmpty {
                            SectionJumpBar(targets: jumpTargets) { id in
                                withAnimation(.easeOut(duration: 0.3)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        ForEach(sections) { section in
                            HomeSectionRow(section: section)
                                .id(section.id)
                        }
                        // Moods & genres as YT-Music-style colorful tiles
                        // (a solid hue per entry with a tilted artwork
                        // corner), not plain carousels.
                        ForEach(moods) { section in
                            MoodGenreSection(section: section)
                                .id(section.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
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
                return HomeSection(id: sec.id, title: sec.title, items: kept)
            }
            moods = mg.compactMap { sec in
                let kept = sec.items.filter { !env.isBlocked($0) }
                guard !kept.isEmpty else { return nil }
                return HomeSection(id: sec.id, title: sec.title, items: kept)
            }
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

/// Horizontal pill bar that scroll-jumps to Explore sections. Pure
/// navigation — no selected state, since it doesn't filter, it moves.
private struct SectionJumpBar: View {
    let targets: [(id: String, label: String)]
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(targets, id: \.id) { target in
                    Button { onPick(target.id) } label: {
                        Text(target.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Theme.Fill.strong, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Jump to \(target.label)")
                }
            }
        }
        .scrollClipDisabled()
    }
}

/// One moods/genres shelf rendered as a colorful tile grid (YT Music's
/// signature look) instead of a horizontal carousel. Each tile is a
/// solid hue with the mood name and a tilted artwork corner, and taps
/// open the mood's curated playlist via the shared navigation.
private struct MoodGenreSection: View {
    let section: HomeSection

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !section.title.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(section.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(section.items) { item in
                    MoodTile(item: item)
                }
            }
        }
    }
}

private struct MoodTile: View {
    let item: MediaItem

    /// Vibrant, dark-ground-friendly palette. A mood keeps the same hue
    /// across the session (stable hash of its id), mirroring the way YT
    /// Music assigns each category a fixed color.
    private static let palette: [Color] = [
        Color(red: 0.84, green: 0.28, blue: 0.26),
        Color(red: 0.90, green: 0.49, blue: 0.18),
        Color(red: 0.86, green: 0.67, blue: 0.18),
        Color(red: 0.28, green: 0.64, blue: 0.40),
        Color(red: 0.18, green: 0.56, blue: 0.64),
        Color(red: 0.24, green: 0.47, blue: 0.80),
        Color(red: 0.42, green: 0.34, blue: 0.76),
        Color(red: 0.66, green: 0.30, blue: 0.66),
        Color(red: 0.82, green: 0.34, blue: 0.53),
        Color(red: 0.36, green: 0.42, blue: 0.52),
    ]

    private var baseColor: Color {
        var h = 5381
        for b in item.id.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return Self.palette[abs(h) % Self.palette.count]
    }

    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [baseColor, baseColor.opacity(0.78)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // Tilted artwork corner — the YT Music mood-tile signature.
                if let url = item.thumbnailURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            Color.black.opacity(0.12)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    .rotationEffect(.degrees(27))
                    .offset(x: 12, y: 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                Text(item.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(12)
            }
            .frame(height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(item.title)
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
