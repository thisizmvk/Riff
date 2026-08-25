import Foundation
import AppKit
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
        // shared container as a separate file. AppKit drawing
        // primitives are main-thread-only, so the task hops back to
        // MainActor after the async URLSession download.
        if let url = thumbnailURL, lastCachedArtwork != url {
            lastCachedArtwork = url
            Task { [url] in
                await Self.cacheArtwork(url: url)
            }
        }
    }

    // Called when there's no active playback so the widget can wipe
    // to its placeholder shell instead of advertising stale state.
    func clear() {
        NowPlayingSnapshotStore.clear()
        lastWritten = nil
        lastWriteAt = .distantPast
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingWidgetIdentifier.kind)
    }

    // MARK: - Artwork cache

    private var lastCachedArtwork: URL?

    static func artworkCacheURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NowPlayingSnapshotStore.appGroupID)
        else { return nil }
        let dir = container.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("current.jpg", isDirectory: false)
    }

    private static func cacheArtwork(url: URL) async {
        guard let dest = artworkCacheURL() else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        // Decode + re-encode at a tiny widget-appropriate size to keep
        // the cached blob small. WidgetKit memory limits on macOS are
        // generous, but the systemSmall family renders ~150pt — we
        // don't need a 600x600 source.
        guard let image = NSImage(data: data) else {
            try? data.write(to: dest, options: .atomic)
            return
        }
        let target = NSSize(width: 256, height: 256)
        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        if let tiff = resized.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? jpg.write(to: dest, options: .atomic)
        } else {
            try? data.write(to: dest, options: .atomic)
        }
    }
}
