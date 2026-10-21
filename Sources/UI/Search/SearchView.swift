import SwiftUI

struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query: String = ""
    /// Live completions for the current query (YT Music's own
    /// suggestions endpoint). Cleared when empty/picked.
    @State private var suggestions: [String] = []
    /// The query string a just-picked suggestion set — suppresses
    /// re-suggesting for the exact text the user just committed.
    @State private var suppressSuggestionsFor: String? = nil
    @State private var filter: SearchFilter = .all
    @FocusState private var searchFieldFocused: Bool
    /// Focused videoId in the result list, or nil when no row is
    /// focused. Enables keyboard traversal: ↑/↓ move, ↵ plays, ⌘↵
    /// adds to queue. Bound onto each SearchResultRow via
    /// `.focused($focusedResultId, equals: item.id)`.
    @FocusState private var focusedResultId: String?
    @State private var yearFilter: YearFilter = .any
    @State private var durationFilter: DurationFilter = .any
    @State private var results: [MediaItem] = []
    @State private var searching: Bool = false
    @State private var errorMessage: String?
    /// The input whose search last landed — `results` and
    /// `nextPageToken` belong to it. Nil before the first search and
    /// whenever `results` is cleared (empty query, failed search).
    /// Lets `debouncedRunSearch` skip the re-fetch SwiftUI fires when
    /// this stack root re-appears (Back from a pushed DetailView), and
    /// keeps "No results for …" hidden until a search has actually
    /// answered the current input.
    @State private var completedInput: SearchInput? = nil
    /// Bumped by the error banner's Retry. Part of `SearchInput`, so a
    /// same-input retry still changes the `.task(id:)` identity and
    /// that task stays the single owner of every search (a keystroke
    /// cancels an in-flight retry instead of racing it).
    @State private var retryToken: Int = 0
    /// Bumped when the recent-searches list is cleared. The list lives
    /// in UserDefaults, which SwiftUI can't observe; `recentSearches`
    /// reads this so Clear re-renders the chip row.
    @State private var recentsRevision: Int = 0
    /// Trimmed text the current `suggestions` were fetched for. Skips
    /// the re-fetch the query-keyed `.task` fires on re-appearance.
    @State private var suggestionsFetchedFor: String? = nil
    /// Token for the next page of search results when YT included one.
    /// Nil before the first search, nil when the result set is
    /// exhausted, and nil under the `.all` filter (heterogeneous
    /// responses don't carry a single top-level continuation).
    @State private var nextPageToken: String? = nil
    /// In-flight guard so a single scroll-to-bottom doesn't fan out
    /// into multiple parallel continuation fetches.
    @State private var loadingMore: Bool = false
    /// Non-nil when the last continuation fetch failed; surfaced as a
    /// retry affordance under the list. We don't clobber the existing
    /// `results` on continuation failure — that would erase rows the
    /// user is still scrolling.
    @State private var loadMoreError: String? = nil
    /// Sort order applied on top of the network results, scoped per
    /// active filter. Hydrated from UserDefaults by `TrackSortMenu`
    /// under `search.sort.{filter}` so the user's "I always sort
    /// songs by play count" preference sticks across sessions, while
    /// "sort albums A-Z" doesn't bleed into the songs view.
    @State private var sort: LibrarySorting.TrackSortOrder = .original

    enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", albums = "Albums", playlists = "Playlists", artists = "Artists", podcasts = "Podcasts"
        var id: String { rawValue }

        /// `params` token sent to /search to scope results. Values cribbed
        /// from `ytmusicapi`'s `parsers/search.py` — they keep these
        /// current; my earlier hand-rolled trailing bytes were wrong and
        /// returned empty result sets for everything except songs.
        var paramsToken: String? {
            switch self {
            case .all:       return nil
            case .songs:     return "EgWKAQIIAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            case .albums:    return "EgWKAQIYAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            case .playlists: return "EgWKAQIoAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            case .artists:   return "EgWKAQIgAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            case .podcasts:  return "EgWKAQJQAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            }
        }
    }

    /// Year buckets — coarse decadal slices that map to InnerTube's
    /// `year` field on `MediaItem`. InnerTube doesn't expose a
    /// `params` token for year filtering on `/search`, so this is a
    /// client-side post-filter applied to the result set.
    ///
    /// Items without a parsed year are dropped under any non-`.any`
    /// filter — better to under-show than to surface unrelated items
    /// the user might think the filter excluded.
    enum YearFilter: String, CaseIterable, Identifiable {
        case any    = "Any year"
        case y2020s = "2020s"
        case y2010s = "2010s"
        case y2000s = "2000s"
        case older  = "Pre-2000"
        var id: String { rawValue }

        func matches(_ year: Int?) -> Bool {
            switch self {
            case .any:    return true
            case .y2020s: return (year ?? -1) >= 2020
            case .y2010s: return (year ?? -1) >= 2010 && (year ?? Int.max) < 2020
            case .y2000s: return (year ?? -1) >= 2000 && (year ?? Int.max) < 2010
            case .older:  return (year ?? 0) > 0 && (year ?? Int.max) < 2000
            }
        }
    }

    /// Length buckets for songs / episodes. Same client-side
    /// post-filter rationale as `YearFilter`. Only applied to
    /// kinds that carry duration — albums/playlists/artists pass
    /// through regardless so we don't accidentally exclude them.
    enum DurationFilter: String, CaseIterable, Identifiable {
        case any    = "Any length"
        case short  = "Short (< 3 min)"
        case medium = "3–7 min"
        case long   = "Long (7+ min)"
        var id: String { rawValue }

        func matches(_ kind: MediaItem.Kind, _ seconds: Int?) -> Bool {
            if self == .any { return true }
            // Don't apply to types that aren't audio tracks.
            guard kind == .song || kind == .episode else { return true }
            guard let s = seconds else { return false }
            switch self {
            case .any:    return true
            case .short:  return s < 180
            case .medium: return s >= 180 && s < 420
            case .long:   return s >= 420
            }
        }
    }

    /// Apply the year + duration filters on top of the network
    /// results, then the active sort. Network response is cached in
    /// `results`; this gets re-evaluated on every filter/sort change
    /// without a refetch.
    private var displayedResults: [MediaItem] {
        let filtered = results.filter { item in
            yearFilter.matches(item.year) && durationFilter.matches(item.kind, item.durationSeconds)
        }
        // Under .all the result set is heterogeneous (mixed kinds), so
        // a "duration" or "play count" sort would compare apples to
        // oranges (an album row has no duration). Skip sorting entirely
        // for .all and preserve YT's relevance order.
        guard filter != .all else { return filtered }
        return LibrarySorting.sortTracks(filtered, by: sort, entries: env.player.playedEntries)
    }

    /// True when at least one refinement is active.
    private var isFiltering: Bool {
        yearFilter != .any || durationFilter != .any
    }

    /// The (query, filter, retry) identity that drives the search task.
    private var currentInput: SearchInput {
        SearchInput(query: query, filter: filter, retry: retryToken)
    }

    /// True from an input change until its search lands — the 300 ms
    /// debounce plus the request. Keeps the pane on "Searching…"
    /// instead of flashing "No results for …" before any request has
    /// been made. False under an error: the banner speaks for itself.
    private var awaitingResults: Bool {
        !query.isEmpty && errorMessage == nil && completedInput != currentInput
    }

    /// Persisted recent-search terms. Reading `recentsRevision` gives
    /// the pre-search branch a state dependency, so Clear (a
    /// UserDefaults-only write) re-renders the row.
    private var recentSearches: [String] {
        _ = recentsRevision
        return SearchView.loadRecentSearches()
    }

    /// Whether the sort menu should appear for the current filter.
    /// Hidden under `.all` (heterogeneous results — sort math doesn't
    /// apply uniformly) and when the result set is empty (no rows to
    /// sort). Shown for every kind-specific filter otherwise.
    private var showsSortMenu: Bool {
        filter != .all && !results.isEmpty
    }

    /// Per-filter UserDefaults key for the sort selection. Scoped so
    /// "Most played" on songs doesn't carry over to a hypothetical
    /// "Most played" on albums where it has a different meaning.
    private var sortPersistenceKey: String {
        "search.sort.\(filter.rawValue)"
    }

    /// Trim the sort options to the ones that make sense for the
    /// active filter. Songs / podcasts surface every order; albums /
    /// playlists / artists drop the duration sorts (album-row
    /// "duration" isn't surfaced in the search response) and the
    /// play-history sorts (we don't journal album-tile plays).
    private var availableSortOrders: [LibrarySorting.TrackSortOrder] {
        switch filter {
        case .songs, .podcasts:
            return LibrarySorting.TrackSortOrder.allCases
        case .albums, .playlists, .artists:
            return [.original, .aToZ, .zToA]
        case .all:
            return [.original]  // not actually shown; menu is hidden
        }
    }

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $env.searchNavPath) { searchContent }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .focused($searchFieldFocused)
                // A pasted music.youtube.com / youtu.be URL opens directly
                // instead of being searched as text.
                .onChange(of: query) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("http"), let url = URL(string: trimmed) else { return }
                    if env.openYouTubeMusicLink(url) { query = "" }
                }
                .onAppear { searchFieldFocused = true }
                .onChange(of: env.focusSearchToken) { _, _ in
                    // ⌘F handler in RiffApp bumps this token; grab
                    // focus into the field on every bump. Runs on
                    // the next runloop tick so the tab switch that
                    // typically precedes the focus request completes
                    // first (SearchView may have been off-screen).
                    Task { @MainActor in searchFieldFocused = true }
                }
                // Suggestions-as-you-type. 150ms debounce (lighter than
                // the 300ms full-search debounce — suggestions should
                // feel instantaneous); cancelled and cleared when the
                // query empties or a suggestion is picked.
                .task(id: query) {
                    let trimmed = query.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, trimmed != suppressSuggestionsFor else {
                        suggestions = []
                        suggestionsFetchedFor = nil
                        return
                    }
                    // Re-appearance (Back from a pushed page) re-runs this
                    // task with the same query; the strip already holds
                    // the suggestions fetched for this text.
                    guard trimmed != suggestionsFetchedFor else { return }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    let fetched: [String]? = try? await env.innerTube.searchSuggestions(query: trimmed)
                    guard !Task.isCancelled else { return }
                    // Suggesting exactly what's already typed is noise.
                    suggestions = (fetched ?? []).filter { $0.lowercased() != trimmed.lowercased() }.prefix(6).map { $0 }
                    // Only a successful fetch counts as done; a failed
                    // one is retried the next time this text runs.
                    if fetched != nil {
                        suggestionsFetchedFor = trimmed
                    } else {
                        suggestionsFetchedFor = nil
                    }
                }

            // Completion strip under the field — YT Music's own
            // suggestions (with typo corrections). Picking one commits
            // it as the query; the existing .task(id:) then runs the
            // real search.
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { s in
                            Button {
                                suppressSuggestionsFor = s
                                suggestions = []
                                query = s
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.Text.tertiary)
                                    Text(s)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.Text.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.Fill.medium)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }

            // Pill-style filter row mirroring YT Music's chips. Horizontal
            // scroll keeps it from clipping when the user resizes the
            // window narrow.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchFilter.allCases) { f in
                        FilterChip(
                            label: f.rawValue,
                            selected: filter == f,
                            action: { filter = f }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }

            // Refinement row — year + duration buckets. Only visible
            // when results exist, so the search input doesn't look
            // overwhelmed when the user hasn't typed yet. Both filter
            // groups scroll horizontally as a single row; a thin
            // section divider separates them visually.
            if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(YearFilter.allCases) { y in
                            RefinementChip(
                                label: y.rawValue,
                                selected: yearFilter == y,
                                action: { yearFilter = y }
                            )
                        }
                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 4)
                        ForEach(DurationFilter.allCases) { d in
                            RefinementChip(
                                label: d.rawValue,
                                selected: durationFilter == d,
                                action: { durationFilter = d }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 2)
                }
                if isFiltering {
                    HStack(spacing: 6) {
                        Text("\(displayedResults.count) of \(results.count) matches")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Text.secondary)
                        Button("Clear") {
                            yearFilter = .any
                            durationFilter = .any
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.red)
                    }
                    .padding(.horizontal, 24)
                }

                // Sort row — shown for every kind-specific filter
                // (songs / albums / playlists / artists / podcasts).
                // The menu picks its own persistence key from `filter`
                // so each filter remembers its own sort independently.
                if showsSortMenu {
                    HStack {
                        Spacer()
                        TrackSortMenu(
                            selection: $sort,
                            surface: .search,
                            persistenceKey: sortPersistenceKey,
                            orders: availableSortOrders
                        )
                    }
                    .padding(.horizontal, 24)
                }
            }

            ScrollView {
                if let errorMessage {
                    // Retry re-keys the `.task(id:)` rather than spawning
                    // an unstructured Task, so every search has one owner
                    // and a keystroke cancels an in-flight retry.
                    ErrorBanner(message: errorMessage) {
                        retryToken &+= 1
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
                if results.isEmpty && (searching || awaitingResults) {
                    // Row skeleton instead of a lone "Searching…" spinner,
                    // so the pane reads as loading results rather than idle.
                    RowListSkeleton()
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                } else if query.isEmpty && results.isEmpty {
                    // Pre-search empty state. Renders recent
                    // searches (if any) as one-tap chips above the
                    // illustrated empty prompt. Users end up
                    // re-searching the same handful of queries most
                    // days; this collapses the ~4 keystrokes of a
                    // typical repeat search to a single click.
                    let recents = recentSearches
                    if !recents.isEmpty {
                        RecentSearchesRow(
                            recents: recents,
                            onPick: { term in query = term },
                            onClear: {
                                SearchView.clearRecentSearches()
                                recentsRevision &+= 1
                            }
                        )
                        .padding(.top, 24)
                    }
                    InitialSearchState(onPick: { query = $0 })
                        .padding(.top, recents.isEmpty ? 60 : 24)
                } else if results.isEmpty, !query.isEmpty, errorMessage == nil {
                    // Reached only once a search has answered this exact
                    // input (`awaitingResults` is false) — never during
                    // the debounce, and never under the error banner.
                    EmptySearchState(query: query)
                        .padding(.top, 80)
                } else if !results.isEmpty && displayedResults.isEmpty {
                    // Refinement narrowed to zero. Distinct from a
                    // genuine "no results for query" — the network
                    // came back fine; the local filter is the gate.
                    VStack(spacing: 8) {
                        Text("No results match these filters.")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Text.secondary)
                        Button("Clear refinements") {
                            yearFilter = .any
                            durationFilter = .any
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else if !results.isEmpty {
                    resultList
                        .padding(.horizontal, 24)
                }
            }
        }
        // Re-run on every (query, filter, retry) change. The 300ms
        // debounce collapses bursts of keystrokes into a single request;
        // .task(id:) cancels the previous in-flight search when inputs
        // change. SwiftUI also re-runs this when the root re-appears
        // after a pop — `debouncedRunSearch` keeps the loaded results
        // in that case instead of re-fetching page 1.
        .task(id: currentInput) {
            await debouncedRunSearch()
        }
        // When the filter changes, reset the sort if the previously-
        // selected order isn't offered by the new filter (e.g. user
        // had "Longest first" on Songs, then flips to Albums where
        // duration sort isn't surfaced). The menu's own `.task(id:)`
        // re-hydrates from the new `search.sort.{filter}` key right
        // after, so a previously-remembered choice on the new filter
        // is restored.
        .onChange(of: filter) { _, _ in
            if !availableSortOrders.contains(sort) {
                sort = .original
            }
        }
        .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
        .navigationDestination(for: HomeSection.self) { SectionGridView(section: $0) }
        // Keyboard navigation across the result list. Live at the
        // container level so the shortcuts fire whenever this pane
        // is on-screen; up/down aren't caret nav for a single-line
        // TextField, so they bubble past the focused search field.
        .onKeyPress(.downArrow) {
            moveFocus(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveFocus(-1)
            return .handled
        }
        .onKeyPress(.return) {
            if let id = focusedResultId, let item = displayedResults.first(where: { $0.id == id }) {
                Task { await play(item) }
                return .handled
            }
            return .ignored
        }
    }

    /// "Top result" hero card + list rows for the rest. Mirrors YT
    /// Music's search layout — the first result is rendered in a wide
    /// card with a prominent Play pill, the remainder as compact list
    /// rows. We also break the list at the kind boundary (Songs /
    /// Albums / Artists / etc.) under the "All" filter so users can
    /// scan by category, the way YT Music does.
    private func moveFocus(_ delta: Int) {
        let ids = displayedResults.map(\.id)
        guard !ids.isEmpty else { return }
        // Steal focus from the search text field on first ↓ so
        // typing doesn't fight the traversal. Users can hit Esc or
        // click the field to return to typing.
        searchFieldFocused = false
        if let current = focusedResultId, let idx = ids.firstIndex(of: current) {
            let next = ((idx + delta) % ids.count + ids.count) % ids.count
            focusedResultId = ids[next]
        } else {
            focusedResultId = delta >= 0 ? ids.first : ids.last
        }
    }

    /// Play any MediaItem — mirrors the row's own play() but usable
    /// from the keyboard handler that lives at container level.
    private func play(_ item: MediaItem) async {
        switch item.kind {
        case .song, .episode: await env.player.play(item: item)
        case .album:          await env.player.playAlbum(id: item.id)
        case .playlist:       await env.player.playPlaylist(id: item.id)
        case .artist:         await env.player.playArtistRadio(id: item.id)
        case .podcast:        await env.player.playPodcast(id: item.id)
        }
    }

    @ViewBuilder
    private var resultList: some View {
        if let top = displayedResults.first {
            VStack(alignment: .leading, spacing: 16) {
                Text("Top result")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                TopResultCard(item: top)
                if displayedResults.count > 1 {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(groupedRest(), id: \.title) { group in
                            if !group.title.isEmpty {
                                Text(group.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)
                            }
                            ForEach(group.items) { item in
                                SearchResultRow(item: item, focusBinding: $focusedResultId)
                            }
                        }
                        loadMoreFooter
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    /// Endless-scroll sentinel rendered at the bottom of the result
    /// list. Behavior:
    ///   - `nextPageToken != nil` and no error: a 1pt invisible
    ///     trigger row that fires `loadMoreIfNeeded()` on appear
    ///     (cheap because the parent is `LazyVStack`), plus a
    ///     ProgressView while a fetch is in flight.
    ///   - `loadMoreError != nil`: a Retry button so the user can
    ///     recover without re-typing the query.
    ///   - neither: empty footer (no infinite-scroll hint when
    ///     there's nothing more to fetch).
    @ViewBuilder
    private var loadMoreFooter: some View {
        if let err = loadMoreError {
            HStack(spacing: 8) {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.secondary)
                Button("Retry") {
                    loadMoreError = nil
                    Task { await loadMoreIfNeeded() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .center)
        } else if nextPageToken != nil {
            // The 1pt sentinel sits inside the LazyVStack so its
            // `.onAppear` only fires when the user has scrolled close
            // enough to the bottom for the row to be materialized.
            Color.clear
                .frame(height: 1)
                .onAppear {
                    Task { await loadMoreIfNeeded() }
                }
            if loadingMore {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading more…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Text.secondary)
                }
                .padding(.top, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// Buckets `displayedResults[1...]` (everything after the top
    /// result) by kind. Under specific-kind filters we collapse to a
    /// single nameless group so we don't show a redundant header.
    private func groupedRest() -> [(title: String, items: [MediaItem])] {
        let rest = Array(displayedResults.dropFirst())
        guard filter == .all else {
            return [(title: "", items: rest)]
        }
        // Preserve YT's original ordering (search shelves come back in
        // a deliberate sequence — Songs first when relevant, etc.) by
        // walking once and only emitting a header when the kind changes.
        var groups: [(title: String, items: [MediaItem])] = []
        var seenKinds: Set<MediaItem.Kind> = []
        for item in rest {
            let title = pluralKind(item.kind)
            if !seenKinds.contains(item.kind) {
                groups.append((title: title, items: [item]))
                seenKinds.insert(item.kind)
            } else if let lastIdx = groups.lastIndex(where: { $0.title == title }) {
                groups[lastIdx].items.append(item)
            }
        }
        return groups
    }

    private func pluralKind(_ kind: MediaItem.Kind) -> String {
        switch kind {
        case .song:     return "Songs"
        case .album:    return "Albums"
        case .playlist: return "Playlists"
        case .artist:   return "Artists"
        case .podcast:  return "Podcasts"
        case .episode:  return "Episodes"
        }
    }

    private struct SearchInput: Hashable {
        let query: String
        let filter: SearchFilter
        /// `retryToken` at issue time — lets a same-input Retry change
        /// the task identity.
        let retry: Int
    }

    /// Resting state shown before the user has typed anything (or after
    /// they've cleared the field). A blank scroll surface reads as
    /// "broken" — the icon + prompt signal that the input is the next
    /// action.
    /// Horizontal chip row of the user's last N successful search
    /// terms. Tapping a chip re-runs that search (via the parent's
    /// `onPick` closure, which just assigns the query string; the
    /// existing `.task(id:)` debounces the network fetch). Header
    /// row includes a "Clear" affordance that wipes the persisted
    /// list — matches the affordance users expect from Chrome /
    /// Safari's own recent-search UI.
    private struct RecentSearchesRow: View {
        let recents: [String]
        let onPick: (String) -> Void
        /// Wipes the persisted list. Owned by the parent so it can bump
        /// its render dependency — a UserDefaults write alone wouldn't
        /// redraw the row.
        let onClear: () -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent searches")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(Theme.Text.tertiary)
                    Spacer()
                    Button("Clear") {
                        onClear()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Text.tertiary)
                }
                .padding(.horizontal, 24)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recents, id: \.self) { term in
                            Button {
                                onPick(term)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 11, weight: .medium))
                                    Text(term)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.Fill.soft)
                                .foregroundStyle(Theme.Text.secondary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    private struct InitialSearchState: View {
        /// Fills the search field with a tapped suggestion; the existing
        /// debounced `.task(id:)` then runs the query.
        let onPick: (String) -> Void

        /// Curated starter queries for a blank search — genres, moods and
        /// eras that always return something, so a first-run search isn't
        /// a staring contest with an empty field.
        private let suggestions = [
            "Lo-fi beats", "Top hits", "Workout", "Focus",
            "Jazz", "90s", "Acoustic", "Chill", "Party", "Running",
        ]

        var body: some View {
            VStack(spacing: 22) {
                EmptyState(
                    systemImage: "magnifyingglass",
                    title: "Find your music",
                    subtitle: "Search for songs, albums, artists, playlists, or podcasts."
                )
                VStack(spacing: 10) {
                    Text("TRY")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.Text.tertiary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                        alignment: .center, spacing: 8
                    ) {
                        ForEach(suggestions, id: \.self) { term in
                            Button { onPick(term) } label: {
                                Text(term)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.Text.primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(Color.white.opacity(0.06)))
                                    .overlay(Capsule().strokeBorder(Theme.Fill.strong, lineWidth: 1))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Search \u{201C}\(term)\u{201D}")
                        }
                    }
                    .frame(maxWidth: 380)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private struct EmptySearchState: View {
        let query: String
        var body: some View {
            EmptyState(
                systemImage: "questionmark.circle",
                title: "No results for \u{201C}\(query)\u{201D}",
                subtitle: "Try a different keyword, or remove a filter."
            )
            .frame(maxWidth: .infinity)
        }
    }

    /// Filter pill — selected state has the YT-Music white pill,
    /// unselected is a dim translucent capsule. Replaces the segmented
    /// picker which couldn't horizontally-scroll on narrow windows.
    private struct FilterChip: View {
        let label: String
        let selected: Bool
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(selected ? Theme.Selected.fill : Theme.Fill.medium)
                    .foregroundStyle(selected ? Theme.Selected.text : Theme.Text.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// Secondary refinement pill — smaller and tinted so the primary
    /// kind row stays visually dominant. Selected state uses the
    /// brand red so the user can tell at a glance which refinements
    /// are active.
    private struct RefinementChip: View {
        let label: String
        let selected: Bool
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(selected ? Theme.Selected.fill : Theme.Fill.soft)
                    .foregroundStyle(selected ? Theme.Selected.text : Theme.Text.secondary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func debouncedRunSearch() async {
        let issued = currentInput
        // SwiftUI re-runs this `.task(id:)` whenever the stack root
        // re-appears (Back from a pushed DetailView) even though the id
        // is unchanged. The loaded results — including every page
        // `loadMoreIfNeeded` appended — already answer this input, so
        // keep them rather than collapsing to page 1. Only drop rows for
        // an artist blocked on the page just left (blocking is
        // otherwise applied at fetch time).
        if issued == completedInput, errorMessage == nil {
            if results.contains(where: { env.isBlocked($0) }) {
                results.removeAll { env.isBlocked($0) }
            }
            return
        }
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            return  // task was cancelled — newer input arrived
        }
        guard issued == currentInput else { return }
        guard !issued.query.isEmpty else {
            results = []
            nextPageToken = nil
            loadMoreError = nil
            errorMessage = nil   // a cancelled in-flight search must not leave its banner on an empty screen
            completedInput = nil
            searching = false
            return
        }
        searching = true
        defer { searching = false }
        do {
            let page = try await env.innerTube.searchPaged(query: issued.query, filter: issued.filter)
            // A response for an input that's no longer current must not
            // land (nor its continuation token).
            guard !Task.isCancelled, issued == currentInput else { return }
            results = page.items.filter { !env.isBlocked($0) }
            nextPageToken = page.continuation
            loadMoreError = nil
            errorMessage = nil
            completedInput = issued
            // Persist to the recent-searches ring only on a
            // SUCCESSFUL non-empty result — no point remembering
            // typos that returned nothing. Runs on the trimmed
            // query so "  hits" and "hits" don't dedupe as
            // separate entries.
            if !page.items.isEmpty {
                Self.rememberRecentSearch(issued.query.trimmingCharacters(in: .whitespaces))
            }
        } catch {
            if Task.isCancelled || LoadErrorPresenter.isCancellation(error) { return }
            guard issued == currentInput else { return }
            results = []
            nextPageToken = nil
            completedInput = nil
            errorMessage = LoadErrorPresenter.message(for: error, env: env)
        }
    }

    // MARK: - Recent searches

    private static let recentSearchesKey = "search.recentQueries"
    private static let recentSearchesLimit = 10

    /// Prepend `query` to the persisted ring buffer of recent
    /// searches. Dedupes case-insensitively — searching "abba" then
    /// "ABBA" collapses to one entry (most-recent form kept).
    /// Skips empty / whitespace-only strings. Runs synchronously
    /// against UserDefaults — the array is at most 10 short
    /// strings, ~200 bytes total.
    static func rememberRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var current = UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
        let needle = trimmed.lowercased()
        // Case-insensitive dedupe, plus prefix collapse: search runs as
        // you type, so every debounced pause that returned results was
        // being remembered — recents filled with fragments ("sai ab"
        // beside "sai abhyankar", "lenin" beside "lenin ost"). An older
        // entry that's a prefix of the new query was the user typing
        // toward it; drop it.
        current.removeAll { prior in
            let p = prior.lowercased()
            return p == needle || needle.hasPrefix(p)
        }
        // And the reverse: if the new query is a prefix of the most
        // recent entry (backspacing out of a finished search), keep the
        // finished one rather than recording the fragment.
        if let latest = current.first?.lowercased(), latest.hasPrefix(needle) {
            return
        }
        current.insert(trimmed, at: 0)
        if current.count > recentSearchesLimit {
            current.removeLast(current.count - recentSearchesLimit)
        }
        UserDefaults.standard.set(current, forKey: recentSearchesKey)
    }

    static func loadRecentSearches() -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
        // Collapse fragments saved before prefix-collapse existed: an
        // entry that's a proper prefix of another entry ("sai ab" vs
        // "sai abhyankar") is a typing artifact, not a search.
        let lowered = stored.map { $0.lowercased() }
        return stored.enumerated().filter { idx, _ in
            let me = lowered[idx]
            return !lowered.enumerated().contains { other, them in
                other != idx && them.count > me.count && them.hasPrefix(me)
            }
        }.map(\.element)
    }

    static func clearRecentSearches() {
        UserDefaults.standard.removeObject(forKey: recentSearchesKey)
    }

    /// Fetch the next page when the user scrolls near the bottom. We
    /// guard against parallel re-entry with `loadingMore` so a brief
    /// scroll-jitter at the bottom doesn't fan out into multiple
    /// concurrent fetches. The token is captured before the async
    /// hop so a stale fetch (user changed filter mid-request) can't
    /// land on the wrong result set — the `query`/`filter` snapshot
    /// is compared on return.
    private func loadMoreIfNeeded() async {
        // `completedInput == currentInput`: the token must belong to
        // what's typed. During a new input's debounce the previous
        // result set (and its token) is still on screen.
        guard let token = nextPageToken,
              !loadingMore,
              !searching,
              !query.isEmpty,
              completedInput == currentInput else { return }
        loadingMore = true
        let issuedQuery = query
        let issuedFilter = filter
        defer { loadingMore = false }
        do {
            let page = try await env.innerTube.searchContinue(token: token)
            // Drop the result if the user changed the input mid-flight.
            guard issuedQuery == query, issuedFilter == filter else { return }
            // De-dupe by id — InnerTube has been seen to return the
            // same row twice across pages, and SwiftUI's ForEach blows
            // up on duplicate ids.
            let existingIds = Set(results.map(\.id))
            let fresh = page.items.filter { !existingIds.contains($0.id) && !env.isBlocked($0) }
            results.append(contentsOf: fresh)
            nextPageToken = page.continuation
            loadMoreError = nil
        } catch {
            if Task.isCancelled || LoadErrorPresenter.isCancellation(error) { return }
            // Don't wipe `results` — the user is mid-scroll. Surface
            // a retry chip under the list instead.
            guard issuedQuery == query, issuedFilter == filter else { return }
            loadMoreError = LoadErrorPresenter.message(for: error, env: env)
        }
    }
}
