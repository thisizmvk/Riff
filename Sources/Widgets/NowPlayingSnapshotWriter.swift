import Foundation
import AppKit
import ImageIO
import Security
import WidgetKit

// Bridges PlayerBridge state into the App-Group-shared
// NowPlayingSnapshot the Notification Center widget reads.
//
// Owns three responsibilities the raw snapshot can't take on:
//   1. Rate-limit writes — onUpdate fires on every ~250ms progress
//      tick. Writing a JSON blob to UserDefaults that often is
//      wasteful and would spam WidgetKit's reload pipeline. We only
//      write when fields the widget actually shows change [track id,
//      play state, large elapsed jumps] or when 10s have elapsed
//      since the last write.
//   2. Notify WidgetKit. After a write, ping
//      WidgetCenter.shared.reloadTimelines so the widget refreshes
//      without waiting for its next scheduled tick.
//   3. Optionally pre-fetch and cache the artwork JPG into the App
//      Group container so the widget can render it without a
//      network round-trip [widgets have aggressive memory limits
//      and network calls during snapshot rendering are flaky].
//      Cached under group container.../Artwork/<sha>.jpg keyed by
//      thumbnail URL — last-write-wins, single-file footprint.
@MainActor
final class NowPlayingSnapshotWriter {
    static let shared = NowPlayingSnapshotWriter()

    // Threshold below which an elapsed-only delta is squelched. Below
    // 10s the widget's own date-aware timeline format handles the
    // tick visually; we don't need to re-write defaults for that.
    // 60s, not 10: every threshold crossing triggers a
    // WidgetCenter.reloadTimelines → a widget-extension render pass.
    // At 10s that was ~6 reloads/min for a whole session, which also
    // burns WidgetKit's daily reload budget; material changes (track,
    // play state) still reload instantly via the delta check.
    private static let elapsedRewriteThresholdSec: TimeInterval = 60

    private var lastWritten: NowPlayingSnapshot?
    private var lastWriteAt: Date = .distantPast

    private init() {}

    // The widget reads everything through the App Group, and the App
    // Group entitlement is off while the widget target is disabled
    // (project.yml: free-team builds can't provision it). Unentitled,
    // every suite write, timeline reload and artwork download/re-encode
    // is pure waste, so the writer idles. Checked once, from the signed
    // entitlements — `containerURL(forSecurityApplicationGroupIdentifier:)`
    // can't gate this: on macOS it returns a path even when unentitled.
    // Re-adding the entitlement (project.yml step 3) re-enables it.
    private static let appGroupEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task, "com.apple.security.application-groups" as CFString, nil
              ),
              let groups = value as? [String]
        else { return false }
        return groups.contains(NowPlayingSnapshotStore.appGroupID)
    }()

    // Called from AppEnvironment.player.onUpdate. Cheap when no
    // material change has happened; expensive [JSON encode + plist
    // write + widget reload] only on real transitions.
    func update(
        videoId: String,
        title: String,
        subtitle: String,
        thumbnailURL: URL?,
        isPlaying: Bool,
        elapsed: Double,
        duration: Double
    ) {
        guard Self.appGroupEntitled else { return }
        let now = Date()
        let snapshot = NowPlayingSnapshot(
            videoId: videoId,
            title: title,
            subtitle: subtitle,
            thumbnailURLString: thumbnailURL?.absoluteString,
            isPlaying: isPlaying,
            updatedAt: now,
            elapsed: elapsed,
            duration: duration
        )

        if let prior = lastWritten {
            let materialChange =
                prior.videoId != snapshot.videoId ||
                prior.isPlaying != snapshot.isPlaying ||
                prior.title != snapshot.title ||
                prior.subtitle != snapshot.subtitle ||
                prior.thumbnailURLString != snapshot.thumbnailURLString ||
                prior.duration != snapshot.duration
            let elapsedDelta = abs(snapshot.elapsed - prior.elapsed)
            let timeSinceWrite = now.timeIntervalSince(lastWriteAt)
            // Squelch progress-only ticks unless either threshold
            // crossed — keeps the App Group plist quiet without
            // letting the widget go stale for minutes on long tracks.
            if !materialChange &&
                elapsedDelta < Self.elapsedRewriteThresholdSec &&
                timeSinceWrite < Self.elapsedRewriteThresholdSec {
                return
            }
        }

        NowPlayingSnapshotStore.write(snapshot)
        lastWritten = snapshot
        lastWriteAt = now

        // Reload the widget timeline. Cheap call when no widget is
        // installed — WidgetKit no-ops it. Available on macOS 11+.
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingWidgetIdentifier.kind)

        // Fire-and-forget artwork cache refresh on track change.
        // Artwork URL is the only field whose payload doesn't fit in
        // UserDefaults [JPG, not metadata], so we copy it to the
        // shared container as a separate file. Download, decode,
        // resize and JPEG encode all run OFF the main actor (ImageIO,
        // not AppKit drawing) so a track transition never hitches.
        if let url = thumbnailURL, lastCachedArtwork != url {
            lastCachedArtwork = url
            Task.detached(priority: .utility) {
                await Self.cacheArtwork(url: url)
            }
        }
    }

    // Called when there's no active playback so the widget can wipe
    // to its placeholder shell instead of advertising stale state.
    func clear() {
        guard Self.appGroupEntitled else { return }
        NowPlayingSnapshotStore.clear()
        lastWritten = nil
        lastWriteAt = .distantPast
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingWidgetIdentifier.kind)
    }

    // MARK: - Artwork cache

    private var lastCachedArtwork: URL?

    nonisolated static func artworkCacheURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NowPlayingSnapshotStore.appGroupID)
        else { return nil }
        let dir = container.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("current.jpg", isDirectory: false)
    }

    // Nonisolated: runs on the global executor, never the main thread.
    // Only thread-safe APIs below (URLSession, ImageIO, Data writes).
    nonisolated private static func cacheArtwork(url: URL) async {
        guard let dest = artworkCacheURL() else { return }
        // Same URL NowPlayingCenter fetches at the same moment — let
        // the shared URLCache serve it instead of a second download.
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        // Decode + re-encode at a tiny widget-appropriate size to keep
        // the cached blob small. WidgetKit memory limits on macOS are
        // generous, but the systemSmall family renders ~150pt — we
        // don't need a 600x600 source.
        if let jpg = widgetJPEG(from: data) {
            try? jpg.write(to: dest, options: .atomic)
        } else {
            try? data.write(to: dest, options: .atomic)
        }
    }

    // ImageIO thumbnail (longest side 256 px, aspect preserved) encoded
    // as JPEG at 0.85. Nil when the bytes don't decode — the caller
    // then stores the original.
    nonisolated private static func widgetJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, thumb, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
