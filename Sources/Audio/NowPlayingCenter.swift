import Foundation
import MediaPlayer
import AppKit

/// Mirrors PlayerBridge state into MPNowPlayingInfoCenter and registers
/// MPRemoteCommandCenter handlers so Control Center, AirPods, keyboard media
/// keys, and Touch Bar can drive playback.
@MainActor
final class NowPlayingCenter {
    private let player: PlayerBridge

    /// In-memory artwork cache keyed by URL absoluteString. The lock screen
    /// re-renders frequently; without a cache we'd refetch the same JPG on
    /// every progress tick. Capped to a small LRU footprint.
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private static let artworkCacheCap = 16
    /// URL whose artwork is currently being fetched — set so concurrent
    /// `update()` calls don't fan out duplicate downloads.
    private var pendingArtworkURL: URL?

    init(player: PlayerBridge) {
        self.player = player
        registerCommands()
    }

    private func registerCommands() {
        let cc = MPRemoteCommandCenter.shared()
        // Idempotent play/pause: the previous code called `togglePlay`
        // from both handlers, which inverted state whenever the OS
        // dispatched the "wrong" command (e.g. Now Playing widget
        // showing stale state, or a Bluetooth remote sending an
        // unconditional Play). Guarding on `isPlaying` makes each
        // command a no-op when we're already in the target state.
        cc.playCommand.isEnabled = true
        cc.pauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled = true
        cc.previousTrackCommand.isEnabled = true
        cc.changePlaybackPositionCommand.isEnabled = true
        // Every handler reads MainActor-isolated state (isPlaying /
        // currentTrack). MPRemoteCommand fires targets on the main
        // queue, so `MainActor.assumeIsolated { ... }` is safe and
        // satisfies Swift 6 strict-concurrency (the addTarget
        // closure itself has no actor isolation). Same pattern
        // used in AppEnvironment for its NotificationCenter blocks.
        cc.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                if !self.player.isPlaying { Task { await self.player.togglePlay() } }
                return .success
            }
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                if self.player.isPlaying { Task { await self.player.togglePlay() } }
                return .success
            }
        }
        // macOS media keys often route through togglePlayPauseCommand
        // rather than the discrete play/pause pair (some kernels
        // dispatch F8 as toggle). Without a handler here, the F8 key
        // silently no-ops even though play/pause are wired.
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                Task { await self.player.togglePlay() }
                return .success
            }
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                Task { await self.player.next() }
                return .success
            }
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return .commandFailed }
                Task { await self.player.previous() }
                return .success
            }
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let event = event as? MPChangePlaybackPositionCommandEvent,
                      let self = self,
                      let track = self.player.currentTrack,
                      track.duration > 0 else { return .commandFailed }
                Task { await self.player.seek(to: event.positionTime / track.duration) }
                return .success
            }
        }
    }

    /// Call after a track change with up-to-date metadata.
    func update(title: String, artist: String, artwork: URL?, duration: Double, elapsed: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork, let cached = artworkCache[artwork.absoluteString] {
            info[MPMediaItemPropertyArtwork] = cached
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // macOS-only: set the explicit playback state. Without this
        // the OS treats the info as advisory metadata and doesn't
        // route media keys / Now Playing widget commands to us —
        // that's why F8, headphone play/pause, and the Control
        // Center widget felt unresponsive. Update on every call so
        // pause/resume transitions flip the OS-visible state.
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused

        // Async artwork fetch on miss. We don't block the metadata write —
        // the lock screen / Control Center will refresh once the image
        // lands. Skip if we're already fetching the same URL.
        if let artwork,
           artworkCache[artwork.absoluteString] == nil,
           pendingArtworkURL != artwork {
            pendingArtworkURL = artwork
            Task { [weak self] in
                await self?.fetchArtwork(url: artwork, currentTitle: title)
            }
        }
    }

    private func fetchArtwork(url: URL, currentTitle: String) async {
        defer { if pendingArtworkURL == url { pendingArtworkURL = nil } }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let nsImage = NSImage(data: data) else { return }
        let artwork = MPMediaItemArtwork(boundsSize: nsImage.size) { _ in nsImage }
        // Stash; trim if over cap (drop arbitrary entries — lock-screen
        // repeats are bounded anyway).
        artworkCache[url.absoluteString] = artwork
        if artworkCache.count > Self.artworkCacheCap {
            for key in artworkCache.keys.prefix(artworkCache.count - Self.artworkCacheCap) {
                artworkCache.removeValue(forKey: key)
            }
        }
        // If the user hasn't switched tracks since we started, push the
        // refreshed metadata. Otherwise the next update() naturally picks
        // up the cached entry.
        guard player.currentTrack?.title == currentTitle else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
