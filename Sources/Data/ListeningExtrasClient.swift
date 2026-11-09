import Foundation

/// Network side of the opt-in listening extras (logic in
/// `Sources/Audio/ListeningExtras.swift`). Both are best-effort: any
/// failure — offline, timeout, 404, bad JSON — returns "nothing", never
/// an error the UI must handle. No account, no cookies, no identifiers
/// beyond what each request needs.
enum ListeningExtrasClient {
    /// LRCLIB asks clients to identify themselves.
    private static let userAgent = "Riff (https://github.com/thisizmvk/Riff)"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    private static func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: LRCLIB

    /// Synced lyrics for a track, or nil. Exact lookup first (title +
    /// artist + duration), then a search on the cleaned-up title,
    /// accepting only a hit within ±3 s of the track's length.
    static func syncedLyrics(title: String, artist: String, duration: Double?) async -> [LRC.Line]? {
        func lines(_ synced: String?) -> [LRC.Line]? {
            guard let synced, !synced.isEmpty else { return nil }
            let parsed = LRC.parse(synced)
            return parsed.isEmpty ? nil : parsed
        }
        func candidate(_ o: [String: Any]) -> LRC.Candidate {
            LRC.Candidate(duration: (o["duration"] as? Double) ?? (o["duration"] as? NSNumber)?.doubleValue,
                          synced: o["syncedLyrics"] as? String,
                          instrumental: (o["instrumental"] as? Bool) ?? false)
        }

        if let d = duration, d > 0 {
            var c = URLComponents(string: "https://lrclib.net/api/get")!
            c.queryItems = [
                .init(name: "track_name", value: title),
                .init(name: "artist_name", value: artist),
                .init(name: "duration", value: String(Int(d.rounded()))),
            ]
            if let url = c.url, let data = await get(url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let match = LRC.bestMatch([candidate(obj)], duration: d), let l = lines(match.synced) {
                return l
            }
        }
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [
            .init(name: "track_name", value: LRC.searchTitle(title)),
            .init(name: "artist_name", value: artist),
        ]
        guard let url = c.url, let data = await get(url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return lines(LRC.bestMatch(arr.prefix(20).map(candidate), duration: duration)?.synced)
    }

    // MARK: SponsorBlock

    /// This video's skippable non-music sections. Uses the hash-prefix
    /// endpoint, so the server only sees a bucket shared by many videos.
    static func nonMusicSegments(videoId: String) async -> [SponsorBlock.Segment] {
        var c = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(SponsorBlock.hashPrefix(videoId: videoId))")!
        c.queryItems = [.init(name: "categories", value: "[\"\(SponsorBlock.category)\"]")]
        guard let url = c.url, let data = await get(url) else { return [] }
        return SponsorBlock.parse(data, videoId: videoId)
    }
}
