import Foundation
import os

/// Per-line lyric translation + optional romanized pronunciation
/// powered by the user's configured `LLMProvider` (B3).
///
/// Architectural notes:
///   - The translator is a `@MainActor` class so the in-memory cache,
///     the in-flight task table, and the consumed views (NowPlayingView's
///     lyrics tab) all sit on the same actor — no cross-actor hops to
///     resolve a cache hit, which is the hot path.
///   - Cache key is `(videoId, targetLanguage)`. No persistence — v1
///     keeps everything in memory; on quit, the cache resets. A cold
///     start re-asks the model, which is fine for the typical session
///     where users translate at most a handful of songs.
///   - The provider is injected, mirroring how `QueueBuilderSheet`
///     uses `AnthropicProvider()` directly today. Tests inject a mock.
///   - The output preserves input line count: missing entries fall
///     back to an empty string so the renderer can still align with the
///     original. The LLM is explicitly told to keep the order and
///     count.
@MainActor
final class LyricsTranslator {

    /// One translated line. `pronunciation` is present only when the
    /// source is non-Latin script; the LLM decides whether to emit it
    /// per-line, and the UI just renders whatever it gets.
    struct TranslatedLine: Sendable, Hashable {
        let translated: String
        let pronunciation: String?
    }

    /// Top-level result for a (videoId, language) pair.
    struct Translation: Sendable, Hashable {
        let lines: [TranslatedLine]
        /// False when the model's reply was cut off mid-array (output
        /// budget hit) and only the leading lines arrived. The tail is
        /// padded with empty entries so indices still line up; the view
        /// can footnote "translation incomplete".
        let isComplete: Bool

        init(lines: [TranslatedLine], isComplete: Bool = true) {
            self.lines = lines
            self.isComplete = isComplete
        }
    }

    /// Languages we surface in the Settings picker. "Other..." is a
    /// separate free-text affordance the user can fill in for anything
    /// not in this list (the LLM will accept any reasonable language
    /// name). Order: English first for the broadest user base, then
    /// the rest grouped roughly by region for predictability.
    static let presetLanguages: [String] = [
        "English",
        "Spanish",
        "French",
        "German",
        "Japanese",
        "Korean",
        "Chinese",
        "Hindi",
        "Telugu",
    ]

    /// UserDefaults key for the user's translation target language.
    /// Defaults to "English" the first time it's read.
    static let languageKey = "lyrics.translationLanguage"
    /// UserDefaults key for whether the lyrics-translation toggle on
    /// the Now Playing lyrics tab is engaged. Persisted so the user's
    /// preference survives quit — once a user has opted in they tend
    /// to want every song translated until they explicitly opt out.
    static let enabledKey = "lyrics.translationEnabled"

    /// System prompt: instructs the model to return exactly one JSON
    /// array entry per input line, including pronunciation only when
    /// the source is non-Latin script. We pin the schema tightly so
    /// the tolerant parser can recover from the usual model-output
    /// noise (markdown fences, trailing commentary).
    static let systemPrompt: String = """
    You are translating song lyrics line by line. The user will give you a target language and a numbered list of lyric lines. \
    Translate each line into the target language. Preserve the input order and count exactly — one output object per input line, in the same order. \
    Each output is an object: {"translated": "...", "pronunciation": "..."}. \
    Include "pronunciation" ONLY when the source is non-Latin script (Japanese kanji/kana, Chinese hanzi, Korean hangul, Devanagari, Telugu, Arabic, Cyrillic, etc.); omit the field or set it to null for Latin-script sources. \
    For instrumental markers like ♪ or empty lines, return {"translated": "", "pronunciation": null}. \
    Output ONLY a JSON array. No prose, no explanation, no markdown code fences.
    """

    /// Output-token budget per request. Every lyric line comes back as
    /// its own `{"translated", "pronunciation"}` object (~35-45 tokens
    /// with romanization, more for long lines or non-Latin targets), so
    /// a fixed 1024 cut off anything past ~30 lines and surfaced as
    /// "Couldn't parse the model's response". Scale with the song; the
    /// floor keeps short songs at the old budget, the ceiling bounds
    /// cost + latency (a longer song still renders the lines that
    /// arrived — see `parseDetailed`).
    static let outputTokensPerLine = 64
    static let outputTokensOverhead = 256
    static let minOutputTokens = 1024
    static let maxOutputTokens = 8192

    static func outputBudget(forLineCount count: Int) -> Int {
        let wanted = max(0, count) * outputTokensPerLine + outputTokensOverhead
        return min(maxOutputTokens, max(minOutputTokens, wanted))
    }

    /// Shown when the reply was cut off before even one line arrived
    /// whole — distinct from the generic parse failure.
    static let truncatedMessage = "These lyrics are too long to translate in one pass — the model's reply was cut off."

    /// Resolve the LLM provider on each call so a key rotation in
    /// Settings takes effect without restarting Riff. Stateless apart
    /// from the cache + in-flight table.
    private let providerFactory: @MainActor () -> any LLMProvider
    private let modelProvider: @MainActor () -> String

    /// In-memory cache. Key is `"\(videoId)|\(language)"` so two
    /// distinct languages on the same track don't collide.
    private var cache: [String: Translation] = [:]

    /// Tasks already in flight for a given cache key — coalesces
    /// concurrent calls (e.g. the user toggles off + on quickly)
    /// so we never fire two requests for the same pair.
    private var inFlight: [String: Task<Translation, Error>] = [:]

    /// Bumped by `clearCache()`. A request that started under an older
    /// generation (old provider / key) still answers its caller but
    /// never writes the cache.
    private var generation = 0

    private static let log = Logger(subsystem: "dev.riff.app", category: "lyrics-translator")

    init(
        providerFactory: @escaping @MainActor () -> any LLMProvider = { AnthropicProvider() },
        modelProvider: @escaping @MainActor () -> String = { AnthropicProvider.storedModel() }
    ) {
        self.providerFactory = providerFactory
        self.modelProvider = modelProvider
    }

    private static func key(videoId: String, language: String) -> String {
        "\(videoId)|\(language.lowercased())"
    }

    /// Synchronous cache lookup. Used by the view to render an
    /// already-resolved translation without re-firing a request.
    func cached(videoId: String, language: String) -> Translation? {
        cache[Self.key(videoId: videoId, language: language)]
    }

    /// Public entry point. Returns cached translation if present;
    /// otherwise asks the LLM, caches, and returns.
    func translate(
        videoId: String,
        language: String,
        lines: [String]
    ) async throws -> Translation {
        let key = Self.key(videoId: videoId, language: language)
        if let hit = cache[key] {
            return hit
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task<Translation, Error> { [providerFactory, modelProvider] in
            let provider = providerFactory()
            let model = modelProvider()
            // Number the input so the model has explicit anchors to
            // keep order. We don't trust the numbering to come back —
            // we trust the array index.
            let numbered = lines.enumerated()
                .map { idx, line in "\(idx + 1). \(line.isEmpty ? "♪" : line)" }
                .joined(separator: "\n")
            let userPrompt = """
            Target language: \(language)

            Lyric lines (one per line, numbered):
            \(numbered)
            """
            let messages: [LLMMessage] = [.system(Self.systemPrompt), .user(userPrompt)]
            // The reply grows with the song, so size the output budget
            // to the input when the provider supports it; otherwise use
            // the provider's fixed default.
            let raw: String
            let truncated: Bool
            if let budgeted = provider as? any BudgetedLLMProvider {
                let reply = try await budgeted.chatReply(
                    messages,
                    model: model,
                    maxTokens: Self.outputBudget(forLineCount: lines.count)
                )
                raw = reply.text
                truncated = reply.truncated
            } else {
                raw = try await provider.chat(messages, model: model)
                truncated = false
            }
            let parsed: (lines: [TranslatedLine], complete: Bool)
            do {
                parsed = try Self.parseDetailed(raw, expectedCount: lines.count)
            } catch {
                // Cut off before a single line arrived whole: say so
                // instead of "couldn't parse".
                if truncated { throw LLMError.network(Self.truncatedMessage) }
                throw error
            }
            return Translation(lines: parsed.lines, isComplete: parsed.complete)
        }
        let startGeneration = generation
        inFlight[key] = task
        defer {
            // clearCache() may have dropped this task and a newer call
            // may have registered its own under the same key — only
            // free the slot if it still holds this task.
            if inFlight[key] == task { inFlight[key] = nil }
        }
        let result = try await task.value
        // Started before a clearCache(): hand the reply to this caller
        // once, but don't cache a result made under the old provider/key.
        if generation == startGeneration {
            cache[key] = result
        }
        return result
    }

    /// Drop everything cached. Wired to the provider switch and the
    /// per-provider "Clear" buttons in Settings so a new backend / key
    /// doesn't inherit translations made under the old one.
    ///
    /// In-flight requests are deliberately not cancelled: the view's own
    /// task isn't cancelled with them, so cancellation surfaced as a red
    /// "Couldn't reach the model: cancelled" under the lyrics. Bumping
    /// `generation` instead keeps their (already-paid-for) reply from
    /// being cached.
    func clearCache() {
        cache.removeAll()
        inFlight.removeAll()
        generation &+= 1
    }

    // MARK: - Parsing

    enum ParseError: Error, Equatable {
        case noJSONArray
    }

    /// Tolerant JSON-array extraction — mirrors `QueueBuilder` but
    /// shaped for our `{translated, pronunciation}` objects. The
    /// returned array is right-sized to `expectedCount`: shorter
    /// outputs are padded with empty entries, longer outputs are
    /// truncated. This keeps the per-line renderer's index alignment
    /// stable even when the model drops or doubles up a line.
    nonisolated static func parse(_ raw: String, expectedCount: Int) throws -> [TranslatedLine] {
        try parseDetailed(raw, expectedCount: expectedCount).lines
    }

    /// `parse`, plus whether the array arrived whole. A reply cut off
    /// mid-array (output budget hit) keeps every element that finished
    /// before the cut — padded like any short reply — and reports
    /// `complete == false`, instead of failing the whole translation.
    nonisolated static func parseDetailed(
        _ raw: String,
        expectedCount: Int
    ) throws -> (lines: [TranslatedLine], complete: Bool) {
        let stripped = stripFences(raw)
        let slice: String
        let complete: Bool
        if let whole = extractJSONArray(stripped) {
            slice = whole
            complete = true
        } else if let partial = salvageTruncatedJSONArray(stripped) {
            slice = partial
            complete = false
        } else {
            throw ParseError.noJSONArray
        }
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw ParseError.noJSONArray
        }
        var out: [TranslatedLine] = []
        out.reserveCapacity(arr.count)
        for entry in arr {
            // Tolerate either an object with the expected fields or a
            // bare string (some models collapse to just the translation
            // when no pronunciation is needed). We never throw on a
            // single bad row — drop to an empty placeholder instead so
            // the index alignment with the source lines is preserved.
            if let obj = entry as? [String: Any] {
                let translated = (obj["translated"] as? String) ?? ""
                let pron: String?
                if let p = obj["pronunciation"] as? String,
                   !p.trimmingCharacters(in: .whitespaces).isEmpty {
                    pron = p
                } else {
                    pron = nil
                }
                out.append(TranslatedLine(translated: translated, pronunciation: pron))
            } else if let s = entry as? String {
                out.append(TranslatedLine(translated: s, pronunciation: nil))
            } else {
                out.append(TranslatedLine(translated: "", pronunciation: nil))
            }
        }
        // Right-size to the expected line count so the UI can index by
        // position without bounds checks.
        if out.count < expectedCount {
            out.append(contentsOf: Array(
                repeating: TranslatedLine(translated: "", pronunciation: nil),
                count: expectedCount - out.count
            ))
        } else if out.count > expectedCount {
            out = Array(out.prefix(expectedCount))
        }
        return (lines: out, complete: complete)
    }

    /// Strip leading / trailing ``` fences (with or without a `json`
    /// language tag). Mirrors the QueueBuilder helper — duplicated
    /// rather than shared so the two AI flows can evolve their
    /// parsing independently.
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

    /// Recovery for an array that never closes (reply cut off at the
    /// output budget): the prefix up to the last top-level element that
    /// finished, re-closed with `]`. Nil when not one element finished.
    /// String-aware like `extractJSONArray`, and counts `{}` as well as
    /// `[]` so only a brace/bracket returning to the array's own level
    /// (or a bare string closing there) marks an element's end.
    nonisolated static func salvageTruncatedJSONArray(_ s: String) -> String? {
        guard let startIdx = s.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var lastElementEnd: String.Index? = nil
        var i = startIdx
        while i < s.endIndex {
            let c = s[i]
            if escape {
                escape = false
            } else if inString {
                if c == "\\" {
                    escape = true
                } else if c == "\"" {
                    inString = false
                    if depth == 1 { lastElementEnd = i }
                }
            } else {
                switch c {
                case "\"":
                    inString = true
                case "[", "{":
                    depth += 1
                case "]", "}":
                    depth -= 1
                    if depth == 1 { lastElementEnd = i }
                    if depth <= 0 { return String(s[startIdx...i]) }
                default:
                    break
                }
            }
            i = s.index(after: i)
        }
        guard let end = lastElementEnd else { return nil }
        return String(s[startIdx...end]) + "]"
    }
}
