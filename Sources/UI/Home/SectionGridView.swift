import SwiftUI

/// Full-shelf page reached from a rail header's "More" button — the
/// whole section as a wrapping tile grid instead of the one-row
/// carousel. Self-contained shelves render their inline items; shelves
/// with a full-catalog endpoint (artist Albums / Singles & EPs) fetch
/// the complete list.
struct SectionGridView: View {
    @Environment(AppEnvironment.self) private var env
    let section: HomeSection

    /// Full catalog fetched from the shelf's "More" browse endpoint
    /// (artist Albums / Singles ship ~10 inline with the whole
    /// discography behind MPAD…). nil until it lands.
    @State private var fullItems: [MediaItem]? = nil
    @State private var loadingFull = false
    @State private var loadFailed = false

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 20)]

    /// Whether this grid is waiting on a full catalog. While it is,
    /// we show a skeleton rather than the ~10 inline items: showing the
    /// partial set first read as "More only shows 10" (field report
    /// 2026-10-20 — the swap to the full list landed seconds later and
    /// in a different order).
    private var expectsFullCatalog: Bool { section.moreBrowseId != nil }

    var body: some View {
        let items = fullItems ?? section.items
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                backButton
                HStack(spacing: 10) {
                    Text(section.title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    if fullItems != nil || !expectsFullCatalog {
                        Text("\(items.count)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Text.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
                if expectsFullCatalog && fullItems == nil && !loadFailed {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading the full catalog…")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    TileGridSkeleton()
                } else {
                    if loadFailed {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Theme.Text.secondary)
                            Text("Couldn't load the full list — showing the first \(items.count).")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Text.secondary)
                            Button("Retry") { Task { await loadFull() } }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.red)
                        }
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            ThumbnailButton(item: item)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, env.player.hasTrack ? 96 : 24)
        }
        .task(id: section.moreBrowseId) {
            guard fullItems == nil else { return }
            await loadFull()
        }
        .background(Theme.Bg.base.ignoresSafeArea())
        // CRITICAL — same rule as DetailView: every pushed page must
        // suppress NavigationStack's automatic back-button toolbar item
        // at the source, or the NSToolbar duplicate-identifier crash
        // returns (multiple mounted tab stacks, one toolbar).
        .navigationBarBackButtonHidden(true)
    }

    private func loadFull() async {
        guard let moreId = section.moreBrowseId else { return }
        loadingFull = true
        loadFailed = false
        defer { loadingFull = false }
        do {
            let fetched = try await env.innerTube.browseSectionMore(
                browseId: moreId, params: section.moreParams
            )
            // An empty/short answer is not "the full catalog" — keep the
            // inline items rather than replacing them with less.
            if fetched.count >= section.items.count {
                fullItems = fetched.filter { !env.isBlocked($0) }
            } else if fetched.isEmpty {
                loadFailed = true
            } else {
                // Non-empty but shorter than the inline set: the inline
                // items are the better list — settle on them (also ends
                // the skeleton, which waits for fullItems or a failure).
                fullItems = section.items
            }
        } catch {
            if Task.isCancelled || LoadErrorPresenter.isCancellation(error) { return }
            loadFailed = true
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
