import Foundation

/// Which LLM backend the user has selected. Persisted in UserDefaults
/// (not Keychain — the choice itself isn't secret; only the API keys
/// each provider stores separately are). Rendered as a segmented
/// picker in Settings; consumed by `AppEnvironment.llmProvider` and
/// by every caller that constructs a provider ad-hoc
/// (`QueueBuilderSheet`, `XRayCardsService`, `LyricsTranslator`).
enum LLMProviderKind: String, CaseIterable, Identifiable, Sendable {
    /// Anthropic Messages API (paid, requires API key + credit).
    case anthropic
    /// Groq LPU cloud (free tier, OpenAI-compatible, API key required
    /// from console.groq.com — free signup, no credit card).
    case groq
    /// Ollama running locally (fully free, no key, no network — the
    /// user runs `ollama serve` and picks a model from
    /// `ollama.com/library`).
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .groq:      return "Groq (free)"
        case .ollama:    return "Ollama (local)"
        }
    }

    /// Short one-liner for the Settings picker help text.
    var tagline: String {
        switch self {
        case .anthropic: return "Claude models — paid API, best quality."
        case .groq:      return "Free hosted Llama / Qwen / Gemma on Groq's LPU cloud. Fast."
        case .ollama:    return "Local models running on this Mac via Ollama. Zero cost, zero network."
        }
    }

    // MARK: - Persistence

    private static let key = "llm.activeProviderKind"

    /// The user's currently-selected provider. Defaults to Anthropic
    /// for existing installs so nothing changes for users who already
    /// pasted an Anthropic key.
    static var active: LLMProviderKind {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let kind = LLMProviderKind(rawValue: raw) else {
                return .anthropic
            }
            return kind
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }

    /// Build a concrete provider for this kind. Ephemeral — call each
    /// time you need one; providers are stateless value types (they
    /// hold at most a URLSession).
    func makeProvider() -> any LLMProvider {
        switch self {
        case .anthropic: return AnthropicProvider()
        case .groq:      return GroqProvider()
        case .ollama:    return OllamaProvider()
        }
    }

    /// Model id the caller should pass to `provider.chat(_:model:)`.
    /// Reads from the provider's own storage — Anthropic has its own
    /// keychain-backed picker, Groq / Ollama use per-kind UserDefaults
    /// slots so switching backends preserves each backend's chosen
    /// model.
    func currentModel() -> String {
        switch self {
        case .anthropic: return AnthropicProvider.storedModel()
        case .groq:      return GroqProvider.storedModel()
        case .ollama:    return OllamaProvider.storedModel()
        }
    }

    /// True when the provider is configured well enough to actually
    /// respond to a chat request. Drives the "AI features are ready"
    /// gate in AppEnvironment + the disabled state on AI-triggering
    /// buttons.
    ///
    /// - Anthropic / Groq: requires a stored API key.
    /// - Ollama: assumed ready if the user picked it (no key to
    ///   validate; the actual reachability check happens on the
    ///   first request).
    func isConfigured() -> Bool {
        switch self {
        case .anthropic: return AnthropicProvider.storedAPIKey()?.isEmpty == false
        case .groq:      return GroqProvider.storedAPIKey()?.isEmpty == false
        case .ollama:    return true
        }
    }
}
