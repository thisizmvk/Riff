import SwiftUI

/// Shared sort-menu pill used on every track-list surface — album /
/// playlist detail pages and search results.
///
/// Centralizes:
///   - The capsule pill visual (matches `LibraryView`'s sort menu so
///     all four surfaces feel like the same control).
///   - Per-surface persistence under a stable UserDefaults key. The
///     caller passes a `persistenceKey` like `"tracks.sort.{id}"` or
///     `"search.sort.{filter}"`; on first appearance the menu hydrates
///     `selection` from UserDefaults, and every change writes back.
///
/// This is *just* the menu; the caller still owns the sorted items
/// array (it depends on data the menu shouldn't know about — env, the
/// play-history journal, the source ordering). Sort *math* lives in
/// `LibrarySorting.sortTracks(_:by:entries:)`.
struct TrackSortMenu: View {
    @Binding var selection: LibrarySorting.TrackSortOrder
    /// Which list surface this menu sits on. Drives only the label of
    /// the `.original` case (e.g. "Album order" vs "Relevance").
    let surface: LibrarySorting.TrackSortSurface
    /// Stable UserDefaults key for this surface's sort preference.
    /// Passing `nil` makes the menu in-memory-only (used for surfaces
    /// where persistence doesn't make sense, like Up Next).
    let persistenceKey: String?
    /// Sort orders shown in the menu. Defaults to all cases; callers
    /// can prune e.g. play-history-derived sorts for surfaces where
    /// the journal has zero useful info.
    let orders: [LibrarySorting.TrackSortOrder]

    init(
        selection: Binding<LibrarySorting.TrackSortOrder>,
        surface: LibrarySorting.TrackSortSurface,
        persistenceKey: String?,
        orders: [LibrarySorting.TrackSortOrder] = LibrarySorting.TrackSortOrder.allCases
    ) {
        self._selection = selection
        self.surface = surface
        self.persistenceKey = persistenceKey
        self.orders = orders
    }

    var body: some View {
        Menu {
            ForEach(orders) { order in
                Button {
                    selection = order
                    persist(order)
                } label: {
                    if selection == order {
                        Label(order.displayName(for: surface), systemImage: "checkmark")
                    } else {
                        Text(order.displayName(for: surface))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(selection.displayName(for: surface))
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.Fill.soft)
            .foregroundStyle(.Theme.Text.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort list")
        .task(id: persistenceKey) {
            // Hydrate from UserDefaults whenever the persistence key
            // changes (e.g. user navigates from album A to album B,
            // each gets its own remembered sort). `.task(id:)`
            // cancels the previous task on key change so we never
            // race two hydrations.
            if let key = persistenceKey,
               let raw = UserDefaults.standard.string(forKey: key),
               let stored = LibrarySorting.TrackSortOrder(rawValue: raw),
               orders.contains(stored) {
                selection = stored
            }
        }
    }

    private func persist(_ order: LibrarySorting.TrackSortOrder) {
        guard let key = persistenceKey else { return }
        UserDefaults.standard.set(order.rawValue, forKey: key)
    }
}
