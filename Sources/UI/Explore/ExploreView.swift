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

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $env.exploreNavPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    ExploreHeader()
                        .padding(.bottom, 4)
                    if let errorMessage {
                        ErrorBanner(message: errorMessage) {
                            Task { await load() }
                        }
                    }
                    if loading && sections.isEmpty {
                        ExploreSkeleton()
                    } else {
                        ForEach(sections) { section in
                            HomeSectionRow(section: section)
                        }
                        ForEach(moods) { section in
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
                .foregroundStyle(.Theme.Text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
