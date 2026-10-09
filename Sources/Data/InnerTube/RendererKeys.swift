import Foundation

/// Single place where every YT Music renderer key lives.
///
/// Why this exists: the InnerTube response shape is undocumented and Google
/// renames these strings on a whim. When `musicShelfRenderer` becomes
/// something else, every callsite that hardcoded the literal breaks at once
/// — and the breakage spans browse, search, library, queue. Centralizing
/// here means the rename is a one-place edit.
///
/// **Do not inline these literals in the parsing code.** If you need a key
/// that isn't here yet, add it here first.
///
/// Last verified working: 2026-05 (clientVersion `1.20260501.00.00`).
/// Since the pageInfo handshake, the constant is a FALLBACK: live
/// requests prefer the page's own version via
/// `InnerTubeClient.effectiveClientVersion`.
enum RendererKeys {
    // MARK: Shelves (containers of items)

    /// Vertical list of rows (e.g. "Trending songs"). Contains
    /// `musicResponsiveListItemRenderer`s under `contents`.
    static let listShelf       = "musicShelfRenderer"

    /// Horizontal carousel (e.g. "Quick picks", "New releases"). Contains
    /// `musicTwoRowItemRenderer`s under `contents`.
    static let carouselShelf   = "musicCarouselShelfRenderer"

    /// Single hero card with featured action (e.g. "Listen again" anchor).
    static let cardShelf       = "musicCardShelfRenderer"

    /// Generic grid of tiles. Items live under `items`, not `contents`.
    static let grid            = "gridRenderer"

    // MARK: Items (individual rows / tiles)

    /// List-row item (search results, library lists, queue tracks).
    static let listItem        = "musicResponsiveListItemRenderer"

    /// Tile item (carousels, home grids).
    static let tileItem        = "musicTwoRowItemRenderer"

    // MARK: Headers (detail-page top section)

    /// Album / playlist detail page header.
    static let detailHeader    = "musicDetailHeaderRenderer"

    /// Modern hero header (newer playlists).
    static let editablePlaylistDetailHeader = "musicEditablePlaylistDetailHeaderRenderer"
    static let responsiveHeader = "musicResponsiveHeaderRenderer"

    /// Artist detail page header.
    static let immersiveHeader = "musicImmersiveHeaderRenderer"

    // MARK: Browse navigation

    /// Top-level wrapper for /browse responses. Tab content lives under
    /// `tabs.0.tabRenderer.content.sectionListRenderer.contents`.
    static let singleColumnBrowse = "singleColumnBrowseResultsRenderer"

    static let tabRenderer        = "tabRenderer"
    static let sectionList        = "sectionListRenderer"

    // MARK: Queue / playback

    /// Container for the up-next queue inside /next responses.
    /// Path: `…content.musicQueueRenderer.content.playlistPanelRenderer`.
    static let queueContainer  = "musicQueueRenderer"
    static let queuePanel      = "playlistPanelRenderer"
    static let queueItem       = "playlistPanelVideoRenderer"

    // MARK: Standard browse path through /browse responses

    /// `["contents", singleColumnBrowse, "tabs", "0", tabRenderer,
    ///   "content", sectionList, "contents"]` — used by browseHome,
    /// library, detail page tracklists.
    // nonisolated(unsafe): an immutable path constant ([Any] can't be
    // Sendable, but this is never mutated after init).
    nonisolated(unsafe) static let homeShelvesPath: [Any] = [
        "contents", singleColumnBrowse, "tabs", "0", tabRenderer,
        "content", sectionList, "contents"
    ]
}
