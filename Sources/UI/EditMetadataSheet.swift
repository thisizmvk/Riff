import SwiftUI

/// D2 — On-device metadata overrides sheet. Pre-populates three
/// TextFields with the *currently displayed* title / artist / album
/// (which is either the prior override, if any, or the original YT
/// value). Save persists the partial override; Clear wipes any
/// override for this track entirely.
///
/// The sheet never talks to YouTube. Overrides are presentation-only
/// and live in `TrackOverrideStore` (UserDefaults JSON).
struct EditMetadataSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let item: MediaItem

    @State private var titleBuffer: String = ""
    @State private var artistBuffer: String = ""
    @State private var albumBuffer: String = ""
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit metadata")
                .font(.system(size: 16, weight: .semibold))
            Text("Changes apply only to this app on this device. Nothing is sent to YouTube.")
                .font(.system(size: 12))
                .foregroundStyle(.Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                fieldRow(label: "Title", text: $titleBuffer)
                fieldRow(label: "Artist", text: $artistBuffer)
                fieldRow(label: "Album", text: $albumBuffer)
            }

            HStack {
                if env.trackOverrides.hasOverride(for: item.id) {
                    Button("Clear override", role: .destructive) {
                        env.trackOverrides.clearOverride(videoId: item.id)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            // Hydrate buffers once. The "Edit metadata" entry-point
            // for a row pre-fills with the *currently displayed*
            // values (i.e. existing override winning over the original).
            guard !didLoad else { return }
            didLoad = true
            if let existing = env.trackOverrides.override(for: item.id) {
                titleBuffer = existing.title ?? item.title
                artistBuffer = existing.artist ?? defaultArtist
                albumBuffer = existing.album ?? defaultAlbum
            } else {
                titleBuffer = item.title
                artistBuffer = defaultArtist
                albumBuffer = defaultAlbum
            }
        }
    }

    private func fieldRow(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.Theme.Text.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Best-effort artist guess from the row's subtitle. YT Music
    /// subtitles look like "Artist · Album · 2016" or "Artist • Album";
    /// the first segment is the artist. For an artist-only subtitle
    /// (no separator) we use the whole string.
    private var defaultArtist: String {
        firstSubtitleSegment(at: 0) ?? item.subtitle
    }

    /// Best-effort album guess — second segment of the subtitle when
    /// present. Many search rows don't include album text, so this
    /// often returns an empty string and the user types it in.
    private var defaultAlbum: String {
        firstSubtitleSegment(at: 1) ?? ""
    }

    private func firstSubtitleSegment(at index: Int) -> String? {
        let segments = item.subtitle
            .split(whereSeparator: { $0 == "·" || $0 == "•" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard index < segments.count else { return nil }
        return segments[index]
    }

    private func save() {
        env.trackOverrides.setOverride(
            videoId: item.id,
            title: titleBuffer,
            artist: artistBuffer,
            album: albumBuffer
        )
        dismiss()
    }
}
