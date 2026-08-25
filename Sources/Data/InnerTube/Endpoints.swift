import Foundation

enum Endpoint: String {
    case search = "search"
    case browse = "browse"
    case next   = "next"
    case player = "player"
    case like         = "like/like"
    case dislike      = "like/dislike"
    case removeLike   = "like/removelike"
    case editPlaylist = "browse/edit_playlist"
    case createPlaylist = "playlist/create"
    case deletePlaylist = "playlist/delete"
    /// Account chrome — display name, channel handle, avatar. Works
    /// with SAPISIDHASH (cookie) auth, so it's the account-details
    /// source for cookie-import sign-ins where the OAuth userinfo
    /// endpoint isn't reachable.
    case accountMenu = "account/account_menu"
}

/// Well-known browseId values used by InnerTube.
/// These are essentially constants the YouTube Music web app sends.
enum BrowseID {
    static let home              = "FEmusic_home"
    static let likedSongs        = "FEmusic_liked_videos"
    static let likedPlaylists    = "FEmusic_liked_playlists"
    static let libraryAlbums     = "FEmusic_library_landing"
    static let libraryArtists    = "FEmusic_library_corpus_track_artists"
    static let libraryPodcasts   = "FEmusic_library_non_music_audio_list"
    static let history           = "FEmusic_history"
    static let explore           = "FEmusic_explore"
    static let moodsAndGenres    = "FEmusic_moods_and_genres"
    static let mixedForYou       = "FEmusic_mixed_for_you"
}
