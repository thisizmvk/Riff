import SwiftUI

/// Pure logic helpers for time-synced karaoke lyrics (B2).
///
/// InnerTube only gives us per-line `startMs`, never per-word. We
/// approximate per-word timing by splitting the line evenly across its
/// duration — the same approach Spotify uses for non-LRC sources. The
/// result is good enough to feel synced; it's not pretending to be
/// hand-authored LRC karaoke.
///
/// Everything in this file is `Sendable` and free of UI state so the
/// math can be unit-tested without spinning up a SwiftUI runtime.
enum LyricsKaraoke {

    /// Find the index of the line whose start time precedes `elapsedMs`
    /// and whose successor's start time exceeds it. Returns -1 when no
    /// line has started yet.
    static func activeLyricIndex(for elapsedMs: Double,
                                 in lines: [InnerTubeClient.LyricLine]) -> Int {
        guard !lines.isEmpty else { return -1 }
        var active = -1
        for (idx, line) in lines.enumerated() {
            guard let startMs = line.startMs else { continue }
            if Double(startMs) <= elapsedMs { active = idx } else { break }
        }
        return active
    }

    /// Duration (ms) of the line at `idx`. Uses the next timed line's
    /// `startMs` as the line's end, falling back to a 3.5s default when
    /// we're at the last line (or the next line has no timing). The
    /// floor of 250ms guards against malformed responses where two
    /// lines share the same startMs (we've seen this on a few tracks).
    static func lineDurationMs(idx: Int,
                               in lines: [InnerTubeClient.LyricLine]) -> Double {
        guard idx >= 0, idx < lines.count else { return 0 }
        let defaultMs: Double = 3_500
        guard let start = lines[idx].startMs else { return defaultMs }
        // Scan forward for the next line that has a startMs strictly
        // greater than this one — skips empty interludes (♪).
        var next: Int? = nil
        for j in (idx + 1)..<lines.count {
            if let s = lines[j].startMs, s > start { next = s; break }
        }
        guard let n = next else { return defaultMs }
        return max(250, Double(n - start))
    }

    /// Progress through the active line as a 0…1 fraction. Used by the
    /// karaoke fill — at 0 the line is fully un-filled, at 1 it's
    /// entirely filled. Clamped on both ends so a seek to the line's
    /// start lands at exactly 0 (no flash of completed fill).
    static func lineProgress(elapsedMs: Double,
                             idx: Int,
                             in lines: [InnerTubeClient.LyricLine]) -> Double {
        guard idx >= 0, idx < lines.count, let start = lines[idx].startMs else { return 0 }
        let dur = lineDurationMs(idx: idx, in: lines)
        guard dur > 0 else { return 0 }
        let raw = (elapsedMs - Double(start)) / dur
        return max(0, min(1, raw))
    }
}

/// Renders a single active lyric line with a left-to-right karaoke fill.
///
/// Approach: a single `Text` with a `LinearGradient` `foregroundStyle`.
/// The gradient has hard stops at `progress` so everything left of the
/// stop is full white and everything right of it is translucent. A 1%
/// feather softens the boundary so the sweep reads as a glide, not a
/// wipe. Using `foregroundStyle` (vs. an overlay-and-mask) lets the
/// `Text` wrap natively for long lines — each visual row gets the same
/// gradient bounding-box, which is the trade-off Spotify also accepts
/// for non-LRC sources.
///
/// We don't have per-word timestamps from InnerTube, so the line's
/// progress is interpolated linearly across the gap to the next timed
/// line — see `LyricsKaraoke.lineProgress`.
struct KaraokeLineView: View {
    let text: String
    /// 0…1 progress through the line.
    let progress: Double

    var body: some View {
        // Use a LinearGradient as the foregroundStyle: two stops at
        // exactly `progress` flip from full white to translucent white.
        // A tiny 1% feather between the stops softens the boundary so
        // the sweep doesn't look like a hard wipe, while still being
        // crisp enough to read as a karaoke fill.
        let p = max(0, min(1, progress))
        let feather: Double = 0.01
        let gradient = LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: p),
                .init(color: Theme.Text.disabled, location: min(1, p + feather)),
                .init(color: Theme.Text.disabled, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        Text(text)
            .foregroundStyle(gradient)
    }

    /// Split preserving trailing whitespace on each token. Retained for
    /// the unit tests — earlier implementations of this view used an
    /// HStack-of-words approach, and the split helper is still the
    /// useful primitive for any future per-word effects (e.g. tap a
    /// specific word once we have per-word timing).
    static func splitWords(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inWord = false
        for ch in text {
            if ch.isWhitespace {
                current.append(ch)
                inWord = false
            } else {
                if !inWord, !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                current.append(ch)
                inWord = true
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }
}
