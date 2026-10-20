import SwiftUI

/// One Moods & Genres category ("Chill", "Bollywood & Indian") — the
/// page a mood tile opens. Fetches FEmusic_moods_and_genres_category
/// with the tile's params and renders the returned curated-playlist
/// shelves with the same HomeSectionRow treatment as Explore itself.
struct MoodCategoryView: View {
    @Environment(AppEnvironment.self) private var env
    let category: InnerTubeClient.MoodCategory

    @State private var sections: [HomeSection] = []
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                backButton
                HStack(spacing: 12) {
                    // YT's own category color as an accent chip next to
                    // the title — ties the page to the tile it came from.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(argb: category.colorARGB))
                        .frame(width: 8, height: 30)
                    Text(category.title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                }
                if let errorMessage {
                    ErrorBanner(message: errorMessage) {
                        Task { await load() }
                    }
                }
                if loading && sections.isEmpty {
                    TileGridSkeleton()
                } else {
                    ForEach(sections) { section in
                        HomeSectionRow(section: section)
                    }
                    if sections.isEmpty && errorMessage == nil {
                        Text("Nothing here right now.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, env.player.hasTrack ? 96 : 24)
        }
        .background(Theme.Bg.base.ignoresSafeArea())
        .task(id: category.params) { await load() }
        // CRITICAL — same rule as DetailView: every pushed page must
        // suppress NavigationStack's automatic back-button toolbar item
        // at the source, or the NSToolbar duplicate-identifier crash
        // returns (multiple mounted tab stacks, one toolbar).
        .navigationBarBackButtonHidden(true)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let raw = try await env.innerTube.browseMoodCategory(params: category.params)
            sections = raw.compactMap { sec in
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

    private func goBack() {
        switch env.activeTab {
        case .home:    if !env.homeNavPath.isEmpty    { env.homeNavPath.removeLast() }
        case .explore: if !env.exploreNavPath.isEmpty { env.exploreNavPath.removeLast() }
        case .search:  if !env.searchNavPath.isEmpty  { env.searchNavPath.removeLast() }
        case .library: if !env.libraryNavPath.isEmpty { env.libraryNavPath.removeLast() }
        }
    }

    private var backButton: some View {
        Button(action: goBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text("Back")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Theme.Fill.strong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")
        .accessibilityLabel("Back")
    }
}

extension Color {
    /// SwiftUI Color from an InnerTube ARGB word (e.g. leftStripeColor).
    init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}
