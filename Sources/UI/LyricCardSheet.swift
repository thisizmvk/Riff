import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "Create lyric card" — small composer that renders a shareable
/// image with a lyric snippet over the track artwork, plus the
/// track's title + artist + a subtle Riff watermark. Saves a PNG
/// via NSSavePanel.
///
/// Lyrics come from `env.player.lyrics(Lines)` — whichever is
/// available — and are pre-seeded into an editable TextField so
/// the user can trim or rephrase. No network calls.
struct LyricCardSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var snippet: String = ""
    @State private var statusMessage: String? = nil

    private var track: PlayerBridge.Track? { env.player.currentTrack }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lyric Card")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let track {
                        LyricCardPreview(track: track, snippet: snippet)
                            .frame(width: 480, height: 480)
                            .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Snippet")
                                .font(.system(size: 11, weight: .semibold))
                                .textCase(.uppercase)
                                .tracking(1.2)
                                .foregroundStyle(Theme.Text.secondary)
                            TextEditor(text: $snippet)
                                .font(.system(size: 14))
                                .frame(minHeight: 80, maxHeight: 140)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(Theme.Fill.soft)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb))
                        }
                        HStack {
                            if let statusMessage {
                                Text(statusMessage)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                            Spacer()
                            Button("Save Image…") {
                                saveImage(for: track)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.red)
                            .disabled(snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
                        Text("Play a track to create a lyric card.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 760)
        .onAppear { seedSnippet() }
    }

    private func seedSnippet() {
        guard snippet.isEmpty else { return }
        if !env.player.lyricsLines.isEmpty {
            // Synced lyrics: pick the active line + the next one so
            // the seed gives the user a natural couplet. "Active" =
            // the last line whose startMs is ≤ current elapsed.
            let lines = env.player.lyricsLines
            let elapsedMs = Int(env.player.elapsed * 1000)
            var activeIdx = 0
            for (idx, line) in lines.enumerated() {
                if let start = line.startMs, start <= elapsedMs {
                    activeIdx = idx
                } else if line.startMs != nil {
                    break
                }
            }
            let pair = lines[activeIdx..<min(activeIdx + 2, lines.count)]
                .map(\.text)
                .filter { !$0.isEmpty }
            snippet = pair.joined(separator: "\n")
        } else if let raw = env.player.lyrics, !raw.isEmpty {
            // Plain-text lyrics: first two non-empty lines.
            let head = raw.split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(2)
                .joined(separator: "\n")
            snippet = head
        }
    }

    private func saveImage(for track: PlayerBridge.Track) {
        let card = LyricCardPreview(track: track, snippet: snippet)
            .frame(width: 1080, height: 1080)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1.0
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            statusMessage = "Could not render the card."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let safeTitle = track.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeTitle) — lyric card.png"
        panel.title = "Save Lyric Card"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
                statusMessage = "Saved."
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}

/// The actual rendered card. Pulled out so we can render it both
/// inline (preview) and at higher resolution for export with a
/// single source-of-truth layout.
private struct LyricCardPreview: View {
    let track: PlayerBridge.Track
    let snippet: String

    var body: some View {
        ZStack {
            // Backdrop: blurred + darkened artwork, falling back to
            // a flat Riff-red gradient if no artwork is loaded.
            if let url = track.thumbnailURL {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 24)
                            .overlay(Color.black.opacity(0.55))
                    } else {
                        Theme.red
                    }
                }
            } else {
                LinearGradient(
                    colors: [Theme.red, .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                Text(snippet)
                    .font(.system(size: 38, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                Spacer()
                HStack(alignment: .center, spacing: 14) {
                    AsyncImage(url: track.thumbnailURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Theme.Fill.medium
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Riff")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Text.secondary)
                        .tracking(2)
                        .textCase(.uppercase)
                }
            }
            .padding(36)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
