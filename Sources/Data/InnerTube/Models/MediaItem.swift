import Foundation

struct MediaItem: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable { case song, album, playlist, artist, podcast, episode }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let thumbnailURL: URL?
    /// For `.song` rows, the album browseId (e.g. `MPREb_…`) when YT
    /// included one in the row's metadata. Drives the "Go to album"
    /// context-menu action. nil for non-songs and for songs whose
    /// source row didn't carry album navigation (some search shelves).
    var albumId: String? = nil
    /// For `.song` and `.album` rows, the primary artist's browseId
    /// (e.g. `UCxx…`). Drives "Go to artist". nil when YT didn't
    /// include an artist navigationEndpoint on the row.
    var artistId: String? = nil
    /// Per-playlist row id for tracks rendered inside a playlist
    /// detail page. Required by InnerTube's editPlaylist
    /// `ACTION_REMOVE_VIDEO` (alongside the videoId itself, since
    /// the same videoId can appear multiple times in a playlist).
    /// nil for rows reached via search / browse / radio queue —
    /// those aren't bound to a playlist context.
    var setVideoId: String? = nil
    /// Track length in seconds, parsed from YT Music's `lengthText`
    /// runs ("3:42" → 222). Drives Search-filter "show only tracks
    /// under N minutes" and Year-end Recap's total-listening-time
    /// stat. nil for non-songs and for rows whose source shelf
    /// omitted the length string (some grid-shaped result sets do).
    var durationSeconds: Int? = nil
    /// Release year for albums / songs / podcast episodes when YT
    /// included it in the row's subtitle runs ("2024" → 2024).
    /// Drives Search-filter "released after year Y" + Recap's
    /// "you played 47 tracks from 2019 this year" stat.
    /// nil for tiles without a year run (artist tiles, most playlists).
    var year: Int? = nil
    /// GLOBAL play/view count label exactly as YT renders it
    /// ("347M plays" / "1.2M views"). Album tracklists carry it in a
    /// flex column; some search/video rows carry "views" in the
    /// byline. Kept as the display string — we never need to sort by
    /// it, and YT's own rounding ("1.2M") is the look we want.
    /// nil when the source row had no such run.
    var playsText: String? = nil
}
