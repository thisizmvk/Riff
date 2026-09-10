import SwiftUI

/// "Vibe → queue" sheet. The user types a natural-language prompt
/// ("rainy Sunday morning, mellow indie folk"), Riff asks the user's
/// configured LLM for a JSON list of {title, artist} suggestions,
/// resolves each one to a real InnerTube song row, and shows the
/// results. The user explicitly opts in via "Play all" or "Add to
/// queue" — Riff never auto-enqueues.
///
/// Raised from the "✨ Build" button in the Up Next pane header. The
/// sheet is unobtrusive when the user hasn't configured an API key
/// yet — it shows a friendly nudge pointing to Settings instead of
/// pretending to be broken.
struct QueueBuilderSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""
    @State private var phase: Phase = .idle
    @State private var resolved: [MediaItem] = []
    @State private var errorMessage: String?

    enum Phase: Equatable {
        case idle
        /// Calling the LLM.
        case generating
        /// Calling InnerTube /search for each suggestion in parallel.
        case resolving
        case done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !env.hasLLMAPIKey {
                        notConfiguredHint
                    } else {
                        promptField
                        if phase == .generating || phase == .resolving {
                            progressBlock
                        }
                        if let errorMessage {
                            errorBlock(errorMessage)
                        }
                        if phase == .done {
                            resultsBlock
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 600)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.red)
                Text("Queue Builder")
                    .font(.system(size: 16, weight: .semibold))
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var notConfiguredHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI features aren't set up yet")
                .font(.system(size: 14, weight: .semibold))
            Text("Add an Anthropic API key in Settings → AI features and Riff can turn a vibe into a queue.")
                .font(.system(size: 12))
                .foregroundStyle(.Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                dismiss()
                env.isSettingsSheetPresented = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.red)
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe a vibe")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(.Theme.Text.secondary)
            TextField("e.g. rainy Sunday morning, mellow indie folk", text: $prompt)
                .textFieldStyle(.roundedBorder)
                .onSubmit(build)
                .disabled(phase == .generating || phase == .resolving)
            HStack {
                Spacer()
                Button(action: build) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Build queue")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || phase == .generating || phase == .resolving)
            }
        }
    }

    private var progressBlock: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(phase == .generating ? "Asking the model…" : "Finding tracks on YouTube Music…")
                .font(.system(size: 12))
                .foregroundStyle(.Theme.Text.secondary)
        }
    }

    private func errorBlock(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var resultsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(resolved.count) tracks")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.Theme.Text.secondary)
                Spacer()
                Button {
                    Task {
                        let tracks = resolved
                        await env.player.playTracks(tracks)
                        dismiss()
                    }
                } label: {
                    Label("Play all", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.red)
                .disabled(resolved.isEmpty)

                Button {
                    for item in resolved {
                        env.player.addToQueueEnd(item: item)
                    }
                    dismiss()
                } label: {
                    Label("Add to queue", systemImage: "text.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(resolved.isEmpty)
            }
            if resolved.isEmpty {
                Text("None of the suggestions matched a track on YouTube Music. Try a more specific vibe.")
                    .font(.system(size: 12))
                    .foregroundStyle(.Theme.Text.secondary)
            } else {
                ForEach(resolved) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .frame(width: 18)
                            .foregroundStyle(.Theme.Text.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.Theme.Text.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Build flow

    private func build() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        resolved = []
        phase = .generating

        // Whichever backend the user picked in Settings — Anthropic,
        // Groq (free hosted), or Ollama (local). Both `provider` and
        // `model` come off `env` so a mid-session switch takes effect
        // immediately.
        let provider = env.llmProvider
        let model = env.llmModel
        let messages: [LLMMessage] = [
            .system(QueueBuilder.systemPrompt),
            .user(trimmed),
        ]

        Task {
            do {
                let raw = try await provider.chat(messages, model: model)
                let suggestions = try QueueBuilder.parseSuggestions(from: raw)
                await MainActor.run { phase = .resolving }
                let items = await QueueBuilder.resolve(
                    suggestions: suggestions,
                    using: env.innerTube
                )
                await MainActor.run {
                    resolved = items
                    phase = .done
                }
            } catch let err as LLMError {
                await MainActor.run {
                    errorMessage = err.errorDescription ?? "Couldn't build a queue."
                    phase = .idle
                }
            } catch QueueBuilder.ParseError.noJSONArray {
                await MainActor.run {
                    errorMessage = "The model didn't return a recognizable list. Try rephrasing."
                    phase = .idle
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't build a queue: \(error.localizedDescription)"
                    phase = .idle
                }
            }
        }
    }
}

/// Static helpers extracted from the SwiftUI view so they're testable.
/// `parseSuggestions(from:)` is the JSON-tolerance layer — models love
/// to wrap their JSON in markdown fences or add commentary before /
/// after the array, and the test suite exercises every flavour we've
/// seen in the wild.
enum QueueBuilder {
    /// The single source of truth for the LLM prompt. Lives here so
    /// QA can adjust wording without spelunking the sheet.
    static let systemPrompt: String = """
    You are a music curator with deep knowledge of contemporary and historical popular music. \
    Given a vibe or mood, return a JSON array of song suggestions tailored to it. \
    Each item is an object: {"title": "song title", "artist": "primary artist name"}. \
    Return between 12 and 20 items. Be specific — real, well-known songs by real artists, not placeholders. \
    Mix expected picks with one or two adventurous ones. \
    Output ONLY the JSON array. No prose, no explanation, no markdown code fences.
    """

    struct Suggestion: Equatable, Sendable {
        let title: String
        let artist: String
    }

    enum ParseError: Error, Equatable {
        case noJSONArray
    }

    /// Tolerant JSON-array extraction. Real models occasionally:
    ///   - Wrap output in ```json … ``` fences
    ///   - Prefix with "Here's a queue:" before the array
    ///   - Add a trailing newline + commentary after the closing `]`
    ///   - Omit one of {title, artist} on a single entry
    /// We strip fences, locate the first `[` and walk to the matching
    /// `]` (depth-tracked, string-aware so brackets inside strings
    /// don't fool us), then JSON-decode. Items missing either field
    /// are dropped silently.
    static func parseSuggestions(from raw: String) throws -> [Suggestion] {
        let stripped = stripFences(raw)
        guard let slice = extractJSONArray(stripped) else {
            throw ParseError.noJSONArray
        }
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ParseError.noJSONArray
        }
        var out: [Suggestion] = []
        for entry in arr {
            guard let obj = entry as? [String: Any] else { continue }
            let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let artist = (obj["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, !artist.isEmpty else { continue }
            out.append(Suggestion(title: title, artist: artist))
        }
        return out
    }

    /// Strip leading / trailing ``` fences (with or without a `json`
    /// language tag). Leaves the interior content untouched.
    static func stripFences(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove a leading fence on its own line.
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

    /// Locate the first balanced top-level JSON array in `s`. Returns
    /// the substring including the outer brackets, or nil if no
    /// balanced array exists. String-aware (ignores `[` / `]` inside
    /// `"..."` literals, handles `\"` escapes).
    static func extractJSONArray(_ s: String) -> String? {
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

    /// Resolve every suggestion to the first matching song row from
    /// `/search`. Runs sequentially — InnerTube is rate-sensitive
    /// and 15 parallel calls have tripped Cloudflare in testing.
    /// Suggestions that don't match anything are dropped; the UI
    /// shows the resulting count.
    @MainActor
    static func resolve(suggestions: [Suggestion], using client: InnerTubeClient) async -> [MediaItem] {
        var out: [MediaItem] = []
        for s in suggestions {
            let query = "\(s.title) \(s.artist)"
            do {
                let hits = try await client.search(query: query, filter: .songs)
                if let song = hits.first(where: { $0.kind == .song }) ?? hits.first {
                    // De-dupe in case the model recommends the same
                    // track twice with slightly different framing.
                    if !out.contains(where: { $0.id == song.id }) {
                        out.append(song)
                    }
                }
            } catch {
                // Silent skip — one bad search shouldn't poison the batch.
                continue
            }
        }
        return out
    }
}
