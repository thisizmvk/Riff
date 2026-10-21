import Foundation

/// Ollama local provider. Assumes the user has `ollama serve` running
/// (default `http://localhost:11434`) and has pulled the model they
/// want via `ollama pull <name>`. Zero cost, zero network egress,
/// works offline.
///
/// The model id is a free-form string (no curated list) because
/// Ollama has hundreds of models across many quant levels and pulling
/// the live tag list from `/api/tags` on every render would be
/// wasteful. Users type the id they installed — `qwen2.5:3b`,
/// `llama3.2:3b`, `gemma2:2b`, `phi3.5:latest`, etc.
///
/// Ollama also exposes an OpenAI-compatible endpoint at
/// `/v1/chat/completions` (added in 0.1.x), so the wire shape is
/// identical to Groq — the shared `OpenAICompatibleChat` helper
/// handles both.
struct OllamaProvider: LLMProvider {
    /// Where the local Ollama daemon listens. Configurable via a
    /// UserDefaults key so a user running `OLLAMA_HOST=0.0.0.0:11500`
    /// or reaching a LAN box can point Riff at the right endpoint
    /// without a rebuild. Stored normalized (see `normalizedBaseURL`);
    /// re-normalized on read so values saved by older builds are fixed.
    private static let baseURLKey = "llm.ollama.baseURL"
    private static let modelKey = "llm.ollama.model"
    /// Sensible small default — Qwen 2.5 3B fits in ~2GB of RAM and
    /// gives punchy output for the queue-builder / translation
    /// prompts. Users should replace with whatever they already
    /// pulled.
    static let defaultModel = "qwen2.5:3b"
    static let defaultBaseURL = URL(string: "http://localhost:11434")!

    /// A handful of small models we surface as picker hints when the
    /// user hasn't typed anything yet. Not an exhaustive list — just
    /// enough to nudge someone who's never used Ollama toward a
    /// reasonable starting point.
    static let suggestedModels: [String] = [
        "qwen2.5:3b",
        "llama3.2:3b",
        "gemma2:2b",
        "phi3.5:latest",
        "qwen2.5:7b",
        "llama3.1:8b",
    ]

    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    var displayName: String { "Ollama" }

    // MARK: - Defaults helpers

    static func storedBaseURL() -> URL {
        guard let raw = UserDefaults.standard.string(forKey: baseURLKey),
              let url = normalizedBaseURL(raw) else {
            return defaultBaseURL
        }
        return url
    }

    /// Store the user's host (empty resets to the default). Returns
    /// false, leaving the previous value in place, when `raw` can't be
    /// turned into an http(s) base URL — so Settings can say so instead
    /// of "saved".
    @discardableResult
    static func setBaseURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: baseURLKey)
            return true
        }
        guard let url = normalizedBaseURL(trimmed) else { return false }
        UserDefaults.standard.set(url.absoluteString, forKey: baseURLKey)
        return true
    }

    /// Turn what a user types into the base URL `OpenAICompatibleChat`
    /// expects (it appends `v1/chat/completions` itself):
    ///   - no scheme (`localhost:11434`, `192.168.1.5:11434`) → `http://…`
    ///   - a trailing `/v1` (the form OpenAI-style clients ask for) or
    ///     the full `/v1/chat/completions` endpoint is dropped, as are
    ///     trailing slashes — otherwise requests hit `/v1/v1/…` and 404.
    /// Nil unless the result is http/https with a host. Ollama-only on
    /// purpose: Groq's base (`…/openai`) relies on the helper appending
    /// `v1/…`, so this must not move into `OpenAICompatibleChat`.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return nil }
        if !s.contains("://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/v1/chat/completions", "/v1"] {
            if let r = s.range(of: suffix, options: [.anchored, .backwards, .caseInsensitive]) {
                s.removeSubrange(r)
                break
            }
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard var components = URLComponents(string: s),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        return components.url
    }

    static func storedModel() -> String {
        let raw = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultModel : raw
    }

    static func setModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: modelKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: modelKey)
        }
    }

    // MARK: - Chat

    func chat(_ messages: [LLMMessage], model: String) async throws -> String {
        // No auth — Ollama trusts localhost. `bearerToken: nil` skips
        // the Authorization header entirely.
        let baseURL = Self.storedBaseURL()
        do {
            return try await OpenAICompatibleChat.chat(
                messages: messages,
                model: model,
                baseURL: baseURL,
                bearerToken: nil,
                session: session,
                providerTag: "ollama"
            )
        } catch LLMError.network(let msg) where !Task.isCancelled && Self.isTransportFailure(msg) {
            // Common Ollama failure: daemon isn't running. Give the
            // user an actionable hint instead of the raw NSError.
            throw LLMError.network("Can't reach Ollama at \(baseURL.absoluteString). Run `ollama serve` and confirm the model \(model) is pulled.")
        } catch LLMError.network(let msg) where msg == "Model error (http_404)" {
            // A 404 with no typed error body: something answered, but
            // not with Ollama's /v1 chat endpoint at this address.
            throw LLMError.network("Ollama at \(baseURL.absoluteString) returned 404. Check the host (e.g. http://localhost:11434) and that the model \(model) is pulled.")
        }
    }

    /// `OpenAICompatibleChat` reports every URLSession failure as
    /// "Couldn't reach the model: <localized reason>". Match that fixed
    /// prefix, not the localized reason (not English outside English
    /// locales); the older substrings stay as a fallback.
    private static func isTransportFailure(_ msg: String) -> Bool {
        msg.hasPrefix("Couldn't reach the model")
            || msg.contains("Could not connect")
            || msg.contains("connection")
            || msg.contains("refused")
    }
}
