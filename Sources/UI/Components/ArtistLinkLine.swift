import SwiftUI

/// A track subtitle ("A, B & C • Album • 2024") rendered with EACH artist
/// as its own link: hover highlights only that name, click opens that
/// artist. The primary (first-credited) artist navigates by browseId
/// when the row carries one; the others resolve by name (see
/// `AppEnvironment.navigateToArtist`). Non-artist segments (album, year,
/// a leading kind label like "Song") render as plain text.
///
/// Replaces the earlier single-link subtitle, which highlighted the
/// entire credit string and could only ever open the first artist.
struct ArtistLinkLine: View {
    let subtitle: String
    let primaryArtistId: String?
    var fontSize: CGFloat = 12
    var baseOpacity: Double = 0.75

    private static let kindLabels: Set<String> = [
        "song", "video", "album", "single", "ep", "playlist", "artist", "episode", "podcast",
    ]

    private struct Segment: Identifiable {
        let id: Int
        let text: String
        let isArtistRun: Bool
    }

    /// Split on YT's "·"/"•" separators; the FIRST segment that isn't a
    /// kind label is the artist run.
    private var segments: [Segment] {
        let parts = subtitle
            .split(whereSeparator: { $0 == "·" || $0 == "•" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var artistAssigned = false
        return parts.enumerated().map { index, part in
            let isArtist = !artistAssigned && !Self.kindLabels.contains(part.lowercased())
            if isArtist { artistAssigned = true }
            return Segment(id: index, text: part, isArtistRun: isArtist)
        }
    }

    /// "A, B & C" / "A and B" → ["A", "B", "C"].
    static func artistNames(in run: String) -> [String] {
        run.replacingOccurrences(of: " & ", with: ", ")
            .replacingOccurrences(of: " and ", with: ", ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { seg in
                if seg.id > 0 { plain(" • ") }
                if seg.isArtistRun {
                    let names = Self.artistNames(in: seg.text)
                    ForEach(Array(names.enumerated()), id: \.offset) { idx, name in
                        if idx > 0 { plain(idx == names.count - 1 ? " & " : ", ") }
                        ArtistNameLink(
                            name: name,
                            artistId: idx == 0 ? primaryArtistId : nil,
                            fontSize: fontSize,
                            baseOpacity: baseOpacity
                        )
                    }
                } else {
                    plain(seg.text)
                }
            }
        }
        .lineLimit(1)
    }

    private func plain(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(.white.opacity(baseOpacity))
    }
}

/// One artist name as a link with its own hover state — so hovering
/// "Jangi Reddy" highlights only Jangi Reddy.
private struct ArtistNameLink: View {
    @Environment(AppEnvironment.self) private var env
    let name: String
    let artistId: String?
    let fontSize: CGFloat
    let baseOpacity: Double
    @State private var hovering = false

    var body: some View {
        Button {
            env.navigateToArtist(name: name, artistId: artistId)
        } label: {
            Text(name)
                .font(.system(size: fontSize))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : baseOpacity))
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Go to \(name)")
        .accessibilityLabel("Go to artist \(name)")
    }
}
