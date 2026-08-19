import Foundation

/// Groq LPU cloud provider. Free tier is generous (~30 req/min for
/// most models), zero cost, sub-second latency — a strong drop-in
/// replacement for Anthropic when the user doesn't want to pay per
/// token. OpenAI-compatible dialect at
/// `https://api.groq.com/openai/v1/chat/completions`.
///
/// Sign-up: console.groq.com → API Keys → Create Key. No credit card.
struct GroqProvider: LLMProvider {
    /// Distinct Keychain slots per provider so switching backends
    /// doesn't wipe the other's credentials, and rotating one
    /// doesn't touch the other.
    static let keychainKeyAccount = "riff.llm.groq"
    static let keychainModelAccount = "riff.llm.groq.model"

    /// Default model — Llama 3.1 8B Instant is the fastest option
    /// (~100+ tok/s), best fit for the queue-builder JSON workload.
    /// Users can upgrade to 3.3 70B for higher-quality lyric
    /// translations / X-Ray cards.
    static let defaultModel = "llama-3.1-8b-instant"

    /// Curated preset list. Pulled from the Groq console's
    /// "production" tier as of late 2025. Groq occasionally deprecates
    /// models; if the stored id isn't in this list we fall back to
    /// the default (see `storedModel`).
    static let availableModels: [String] = [
        "llama-3.1-8b-instant",
        "llama-3.3-70b-versatile",
        "qwen-2.5-32b",
        "gemma2-9b-it",
        "mixtral-8x7b-32768",
    ]

    private static let baseURL = URL(string: "https://api.groq.com/openai")!

    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    var displayName: String { "Groq" }

    // MARK: - Keychain / defaults helpers

    static func storedAPIKey() -> String? { Keychain.get(keychainKeyAccount) }

    static func storedModel() -> String {
        let stored = Keychain.get(keychainModelAccount) ?? defaultModel
        return availableModels.contains(stored) ? stored : defaultModel
    }

    static func setAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(keychainKeyAccount)
            return
        }
        try Keychain.set(trimmed, for: keychainKeyAccount)
    }

    static func setModel(_ id: String) {
        try? Keychain.set(id, for: keychainModelAccount)
    }

    static func clearAPIKey() {
        Keychain.delete(keychainKeyAccount)
        Keychain.delete(keychainModelAccount)
    }

    // MARK: - Chat

    func chat(_ messages: [LLMMessage], model: String) async throws -> String {
        guard let key = Self.storedAPIKey(), !key.isEmpty else {
            throw LLMError.unauthorized
        }
        return try await OpenAICompatibleChat.chat(
            messages: messages,
            model: model,
            baseURL: Self.baseURL,
            bearerToken: key,
            session: session,
            providerTag: "groq"
        )
    }
}
