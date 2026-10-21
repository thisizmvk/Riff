import Foundation
import os

/// Shared implementation of an OpenAI /v1/chat/completions request.
/// Groq and Ollama both expose this dialect verbatim, so the actual
/// per-provider work is just picking the base URL, adding the right
/// auth header, and picking a model id. Extracted here so a new
/// OpenAI-shaped provider (Together, Cerebras, Fireworks, …) is a
/// ~20-line struct.
enum OpenAICompatibleChat {
    private static let log = Logger(subsystem: "dev.riff.app", category: "llm")

    /// POST /v1/chat/completions with the standard OpenAI JSON shape.
    /// `baseURL` is the origin+path prefix (e.g.
    /// `https://api.groq.com/openai` or `http://localhost:11434`). We
    /// append `/v1/chat/completions` internally so callers can't drift
    /// on the path.
    ///
    /// `bearerToken` becomes `Authorization: Bearer <token>` when
    /// non-nil; Ollama omits it entirely.
    ///
    /// `providerTag` is used in log lines for triage — never sent
    /// over the wire.
    static func chat(
        messages: [LLMMessage],
        model: String,
        baseURL: URL,
        bearerToken: String?,
        session: URLSession,
        providerTag: String
    ) async throws -> String {
        // OpenAI-style messages: [{role, content}], system stays
        // inline (unlike Anthropic which lifts it to a top-level
        // field). Both Groq and Ollama respect the inline shape.
        let wireMessages = messages.map { msg in
            ["role": msg.role.rawValue, "content": msg.content]
        }
        let body: [String: Any] = [
            "model": model,
            "messages": wireMessages,
            "max_tokens": 1024,
            // stream=false so the whole response arrives in one shot
            // and we don't have to plumb SSE parsing for what are
            // ~200-token chat completions. Both providers respect this.
            "stream": false,
        ]

        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let bearerToken, !bearerToken.isEmpty {
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            log.error("\(providerTag, privacy: .public) transport error: \(error.localizedDescription, privacy: .public)")
            throw LLMError.network("Couldn't reach the model: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network("Unexpected response type")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            log.error("\(providerTag, privacy: .public) 401/403 — key rejected")
            throw LLMError.unauthorized
        case 429:
            log.error("\(providerTag, privacy: .public) 429 — rate limited")
            throw LLMError.rateLimited
        default:
            let safeType = errorType(from: data) ?? "http_\(http.statusCode)"
            log.error("\(providerTag, privacy: .public) http \(http.statusCode) type=\(safeType, privacy: .public)")
            throw LLMError.network("Model error (\(safeType))")
        }

        // OpenAI response shape:
        //   { "choices": [{ "message": { "role": "assistant", "content": "..." } }, …] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.isEmpty
        else {
            throw LLMError.empty
        }
        return text
    }

    /// Extract a short, non-secret error type from an OpenAI-style
    /// error body (`{"error": {"type": "…", "code": "…", "message": "…"}}`).
    /// Prefers `code`, falls back to `type`. Never returns the raw
    /// message (may echo request contents).
    private static func errorType(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any] else {
            return nil
        }
        return (err["code"] as? String) ?? (err["type"] as? String)
    }
}
