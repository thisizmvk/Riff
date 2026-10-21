import Foundation
import os

/// Generates X-Ray context cards for a song via the user's configured
/// `LLMProvider` (B4). Cards surface lyric references — people, places,
/// events, sample sources, trivia — as a vertical magazine-style stack
/// on the Now Playing pane.
///
/// Architectural notes:
///   - Mirrors `LyricsTranslator` (B3) intentionally: `@MainActor`,
///     in-memory cache keyed by videoId, in-flight task table for
///     coalescing, tolerant JSON-array parser. Two AI flows side by
///     side with the same shape makes the surface easy to reason
///     about.
///   - Cache key is just `videoId` — unlike translation we don't
///     vary by language because the cards summarize trivia in the
///     UI's locale (English) and the user can re-roll by clearing
///     the key. If lyrics arrive late, the first cached result is
///     authoritative; we don't re-fire when lyrics land later since
///     the people / places / era cards are usually answerable from
///     title + artist alone.
///   - The provider is captured via a `@MainActor` factory so a key
///     rotation in Settings takes effect without rebuilding the
///     service.
@MainActor
final class XRayCardsService {

    /// Closed set of card kinds — the LLM is told to use one of these
    /// per card so the renderer can pick an SF Symbol + accent without
    /// string-matching on freeform values. Unknown kinds fall back to
    /// `.trivia`.
    enum CardKind: String, Sendable, Codable, CaseIterable {
        case people
        case place
        case event
        case sample
        case trivia

        var systemImage: String {
            switch self {
            case .people:  return "person.2"
            case .place:   return "mappin.and.ellipse"
            case .event:   return "calendar"
            case .sample:  return "waveform"
            case .trivia:  return "sparkles"
            }
        }

        /// Human-readable label rendered as a small uppercase tag
        /// above each card title.
        var label: String {
            switch self {
            case .people:  return "People"
            case .place:   return "Place"
            case .event:   return "Era"
            case .sample:  return "Sample"
            case .trivia:  return "Trivia"
            }
        }
    }

    /// One context card. `title` is a short noun phrase; `body` is
    /// 2-4 sentences of flavor text. The renderer never trusts these
    /// to be HTML-safe — they're plain text rendered into `Text`.
    struct Card: Sendable, Hashable, Identifiable {
        let id: UUID
        let title: String
        let body: String
        let kind: CardKind

        init(id: UUID = UUID(), title: String, body: String, kind: CardKind) {
            self.id = id
            self.title = title
            self.body = body
            self.kind = kind
        }
    }

    struct Bundle: Sendable, Hashable {
        let cards: [Card]
    }

    /// System prompt: pins the JSON schema tightly so the tolerant
    /// parser has a stable target. We explicitly forbid speculation
    /// about real living people's private lives and tell the model
    /// to skip a card kind rather than fabricating content.
    static let systemPrompt: String = """
    You are an expert music journalist writing short context cards for a song. \
    Given a title, artist, and (optionally) lyrics, produce 3-6 short cards covering: \
    notable PEOPLE mentioned in the lyrics or central to the song's creation, \
    PLACES mentioned in the lyrics or relevant to the song, \
    historical EVENTS or era context that inform the song, \
    musical SAMPLES or interpolations the song uses, \
    and one interesting piece of TRIVIA. \
    Each card is an object: {"title": "...", "body": "...", "kind": "people|place|event|sample|trivia"}. \
    Keep each title to a short noun phrase (under 60 chars). Body is 2-4 sentences of plain text. \
    If you don't have reliable information for a category, OMIT it — never fabricate. \
    Do not write anything that could be defamatory about a real living person. \
    Output ONLY a JSON array. No prose, no explanation, no markdown code fences.
    """

    /// Lyric lines are truncated to this many entries before being
    /// sent — even very long songs cap here. Keeps tokens bounded
    /// and the model focused on the verse content.
    static let maxLyricLines = 60

    private let providerFactory: @MainActor () -> any LLMProvider
    private let modelProvider: @MainActor () -> String

    private var cache: [String: Bundle] = [:]
    private var inFlight: [String: Task<Bundle, Error>] = [:]

    private static let log = Logger(subsystem: "dev.riff.app", category: "xray-cards")

    init(
        providerFactory: @escaping @MainActor () -> any LLMProvider = { AnthropicProvider() },
        modelProvider: @escaping @MainActor () -> String = { AnthropicProvider.storedModel() }
    ) {
        self.providerFactory = providerFactory
        self.modelProvider = modelProvider
    }

    /// Synchronous cache lookup. Views call this on first render so a
    /// cached bundle paints without a loading flash.
    func cached(videoId: String) -> Bundle? {
        cache[videoId]
    }

    /// Public entry point. Returns cached bundle if present; otherwise
    /// asks the LLM, caches, returns. `lyrics` is optional — the model
    /// can still produce era / trivia cards from title + artist alone.
    func cards(
        videoId: String,
        title: String,
        artist: String,
        lyrics: [String]?
    ) async throws -> Bundle {
        if let hit = cache[videoId] {
            return hit
        }
        if let existing = inFlight[videoId] {
            return try await existing.value
        }
        let task = Task<Bundle, Error> { [providerFactory, modelProvider] in
            let provider = providerFactory()
            let model = modelProvider()
            let lyricsBlock: String
            if let lyrics, !lyrics.isEmpty {
                let trimmed = Array(lyrics.prefix(Self.maxLyricLines))
                lyricsBlock = """

                Lyrics (may be partial):
                \(trimmed.joined(separator: "\n"))
                """
            } else {
                lyricsBlock = "\n\nLyrics: (not available — answer from your knowledge of title + artist)"
            }
            let userPrompt = """
            Title: \(title)
            Artist: \(artist)\(lyricsBlock)
            """
            let raw = try await provider.chat(
                [.system(Self.systemPrompt), .user(userPrompt)],
                model: model
            )
            let cards = try Self.parse(raw)
            return Bundle(cards: cards)
        }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        let result = try await task.value
        cache[videoId] = result
        return result
    }

    /// Drop everything cached. Wired to "Clear key" in Settings so a
    /// fresh key doesn't inherit cards generated under the old one.
    func clearCache() {
        cache.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Parsing

    enum ParseError: Error, Equatable {
        case noJSONArray
    }

    /// Tolerant JSON-array extraction — same shape as
    /// `LyricsTranslator.parse` but typed for the card schema. We
    /// silently coerce malformed rows to safe defaults rather than
    /// throwing on a single bad object, so a partial response still
    /// renders the cards that parsed cleanly.
    nonisolated static func parse(_ raw: String) throws -> [Card] {
        let stripped = stripFences(raw)
        guard let slice = extractJSONArray(stripped) else {
            throw ParseError.noJSONArray
        }
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw ParseError.noJSONArray
        }
        var out: [Card] = []
        out.reserveCapacity(arr.count)
        for entry in arr {
            guard let obj = entry as? [String: Any] else { continue }
            let title = (obj["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = (obj["body"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Drop empty cards — the renderer would show a blank
            // section otherwise. Title-only cards are allowed (the
            // body row just hides).
            if title.isEmpty && body.isEmpty { continue }
            let kindStr = (obj["kind"] as? String)?.lowercased() ?? ""
            let kind = CardKind(rawValue: kindStr) ?? .trivia
            out.append(Card(title: title, body: body, kind: kind))
        }
        return out
    }

    /// Strip leading / trailing ``` fences (with or without a `json`
    /// language tag). Duplicated from `LyricsTranslator` rather than
    /// shared so the two AI flows can evolve independently.
    nonisolated static func stripFences(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            } else {
                s = String(s.dropFirst(3))
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First balanced top-level JSON array. String-aware so brackets
    /// inside `"..."` don't fool the depth tracker.
    nonisolated static func extractJSONArray(_ s: String) -> String? {
        guard let startIdx = s.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = startIdx
        while i < s.endIndex {
            let c = s[i]
            if escape {
                escape = false
            } else if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "[":  depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 {
                        return String(s[startIdx...i])
                    }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
