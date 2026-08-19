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
    /// without a rebuild. Stored raw string; validated on read.
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
              let url = URL(string: raw) else {
            return defaultBaseURL
        }
        return url
    }

    static func setBaseURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: baseURLKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: baseURLKey)
        }
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
        do {
            return try await OpenAICompatibleChat.chat(
                messages: messages,
                model: model,
                baseURL: Self.storedBaseURL(),
                bearerToken: nil,
                session: session,
                providerTag: "ollama"
            )
        } catch LLMError.network(let msg) where msg.contains("Could not connect")
                                             || msg.contains("connection")
                                             || msg.contains("refused") {
            // Common Ollama failure: daemon isn't running. Give the
            // user an actionable hint instead of the raw NSError.
            throw LLMError.network("Can't reach Ollama at \(Self.storedBaseURL().absoluteString). Run `ollama serve` and confirm the model \(model) is pulled.")
        }
    }
}
