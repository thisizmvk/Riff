import Foundation
import CryptoKit

/// Pure logic behind two opt-in listening extras. Networking lives in
/// `ListeningExtrasClient.swift`; everything here is deterministic and
/// harness-tested.
///
///   - LRC: synced lyrics from LRCLIB when YouTube has none (or only
///     unsynced text).
///   - SponsorBlock: community-marked non-music sections of music
///     videos (intros, skits, outros) — category `music_offtopic` only.

// MARK: - LRC synced lyrics

enum LRC {
    struct Line: Equatable, Sendable {
        let startMs: Int
        let text: String
    }

    /// Parse LRC text: `[mm:ss.xx] words`, including multiple timestamps
    /// on one line (`[00:12.00][01:30.00] chorus`). Metadata tags
    /// (`[ar:…]`, `[length:…]`) and untimed lines are dropped; empty
    /// lyric lines (instrumental gaps) become "♪". Sorted by time.
    static func parse(_ lrc: String) -> [Line] {
        var out: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var stamps: [Int] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let ms = millis(tag) else { break }
                stamps.append(ms)
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for ms in stamps { out.append(Line(startMs: ms, text: text.isEmpty ? "♪" : text)) }
        }
        return out.sorted { $0.startMs < $1.startMs }
    }

    /// "mm:ss", "mm:ss.xx" or "mm:ss.xxx" → milliseconds.
    private static func millis(_ tag: Substring) -> Int? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[0]), m >= 0,
              let s = Double(parts[1]), s >= 0, s < 60 else { return nil }
        return m * 60_000 + Int((s * 1000).rounded())
    }

    /// Strip YouTube title decorations that LRCLIB won't have:
    /// "Aaya Sher (From \"The Paradise\") (Telugu)" → "Aaya Sher",
    /// "Song [Official Video]" → "Song", "Song - Remastered 2011" kept
    /// as-is (that dash is often part of the real title).
    static func searchTitle(_ title: String) -> String {
        var t = title
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let o = t.range(of: open), let c = t.range(of: close, range: o.upperBound..<t.endIndex) {
                t.removeSubrange(o.lowerBound..<c.upperBound)
            }
        }
        let cleaned = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? title : cleaned
    }

    /// One LRCLIB search hit, reduced to what matching needs.
    struct Candidate: Equatable, Sendable {
        let duration: Double?
        let synced: String?
        let instrumental: Bool
    }

    /// Best synced candidate within ±3 s of the track's duration
    /// (closest wins). With no known duration, the first synced hit.
    /// A wrong-version match (radio edit vs album cut) would drift out
    /// of sync, so duration-mismatched hits are rejected outright.
    static func bestMatch(_ candidates: [Candidate], duration: Double?) -> Candidate? {
        let synced = candidates.filter { !$0.instrumental && !($0.synced ?? "").isEmpty }
        guard let d = duration, d > 0 else { return synced.first }
        return synced
            .compactMap { c -> (Candidate, Double)? in
                guard let cd = c.duration else { return nil }
                let diff = abs(cd - d)
                return diff <= 3 ? (c, diff) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }
}

// MARK: - SponsorBlock (music_offtopic)

enum SponsorBlock {
    static let category = "music_offtopic"
    /// Segments shorter than this are trims, not sections — skipping a
    /// one-second sliver just feels like a glitch.
    static let minimumLength: Double = 2

    struct Segment: Equatable, Sendable {
        let start: Double
        let end: Double
        let uuid: String
        /// Length of the video the segment was submitted against
        /// (0 = unknown). Guards against skipping inside an ad.
        let videoDuration: Double
    }

    /// First 4 hex chars of SHA-256(videoId). The k-anonymous lookup:
    /// the server only learns a bucket shared by many videos, never
    /// which one is playing.
    static func hashPrefix(videoId: String) -> String {
        let digest = SHA256.hash(data: Data(videoId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(4).description
    }

    /// Parse a hash-prefix bucket response down to THIS video's skippable
    /// music_offtopic segments, sorted. Anything malformed → [].
    static func parse(_ data: Data, videoId: String) -> [Segment] {
        guard let bucket = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let mine = bucket.first(where: { ($0["videoID"] as? String) == videoId }),
              let segs = mine["segments"] as? [[String: Any]] else { return [] }
        return segs.compactMap { s -> Segment? in
            guard (s["category"] as? String) == category,
                  (s["actionType"] as? String ?? "skip") == "skip",
                  let pair = s["segment"] as? [Double], pair.count == 2,
                  pair[1] - pair[0] >= minimumLength else { return nil }
            return Segment(start: pair[0], end: pair[1],
                           uuid: s["UUID"] as? String ?? "\(pair[0])-\(pair[1])",
                           videoDuration: (s["videoDuration"] as? Double) ?? 0)
        }
        .sorted { $0.start < $1.start }
    }

    /// The segment to skip at `time`, if any: inside [start, end − 0.5)
    /// and not already skipped (a user who seeks back into a section is
    /// allowed to hear it). Refused when the playing duration doesn't
    /// match the duration the segment was marked against — that's an
    /// ad, or a different cut of the video.
    static func segmentToSkip(at time: Double, playingDuration: Double,
                              expectedDuration: Double?, in segments: [Segment],
                              alreadySkipped: Set<String>) -> Segment? {
        guard let seg = segments.first(where: { time >= $0.start && time < $0.end - 0.5 }),
              !alreadySkipped.contains(seg.uuid) else { return nil }
        let known = (expectedDuration ?? 0) > 0 ? expectedDuration! : (seg.videoDuration > 0 ? seg.videoDuration : nil)
        if let known, playingDuration > 0, abs(playingDuration - known) > 3 { return nil }
        return seg
    }

    /// Where to land after skipping: the segment end, but never past the
    /// last moments of the track (an outro skip should END the track
    /// naturally, not seek beyond it).
    static func landingTime(for seg: Segment, playingDuration: Double) -> Double {
        guard playingDuration > 0 else { return seg.end }
        return min(seg.end, max(playingDuration - 0.3, 0))
    }
}
