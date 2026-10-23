import SwiftUI
import UniformTypeIdentifiers

/// "Your Taste" — everything Riff's taste model knows, in plain view.
/// Same `TasteProfile` that biases Riff Blend, so nothing shapes the mix
/// that isn't shown here. Built on-device from the play journal; the
/// export / import / reset actions hand the user full control of it.
struct TasteView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        let taste = TasteProfile.build(from: env.player.playedEntries)
        let top = taste.topArtists(limit: 8)
        let maxPlays = max(top.first?.plays ?? 1, 1)

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Taste")
                        .font(.system(size: 24, weight: .bold))
                    Text("What Riff has learned from your last \(TasteProfile.windowDays) days — computed on this Mac, never sent anywhere.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Text.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider().background(Theme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if top.isEmpty {
                        EmptyState(systemImage: "waveform",
                                   title: "Nothing learned yet",
                                   subtitle: "Play some music — your taste builds up from what you listen to.",
                                   cta: nil)
                    } else {
                        section("Top artists") {
                            ForEach(top) { a in
                                HStack(spacing: 10) {
                                    Text(a.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .frame(width: 180, alignment: .leading)
                                        .lineLimit(1)
                                    GeometryReader { geo in
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Theme.red.opacity(0.85))
                                            .frame(width: max(4, geo.size.width * Double(a.plays) / Double(maxPlays)))
                                    }
                                    .frame(height: 8)
                                    Text("\(a.plays)")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Theme.Text.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                }
                            }
                        }

                        section(taste.isWeekendNow ? "Your weekend sound" : "Your weekday sound",
                                caption: "Artists you lean into on this kind of day. Blend plays them a little more today.") {
                            let favs = taste.dayTypeFavorites
                            if favs.isEmpty {
                                hint("No clear pattern yet — needs a few weeks of both weekday and weekend listening.")
                            } else {
                                chips(favs.map(\.name))
                            }
                        }

                        section("Easing off",
                                caption: "Blend plays these less for now — because you've had a lot of them lately, or often skip them.") {
                            let eased = taste.easedOff
                            if eased.isEmpty {
                                hint("Nothing — your listening is nicely varied.")
                            } else {
                                ForEach(eased.prefix(6)) { a in
                                    HStack {
                                        Text(a.name).font(.system(size: 13, weight: .medium))
                                        Spacer()
                                        Text(easeReason(a, taste))
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.Text.secondary)
                                    }
                                }
                            }
                        }

                        section("How Riff Blend picks songs") {
                            VStack(alignment: .leading, spacing: 6) {
                                bullet("Songs you play often and recently count most.")
                                bullet("Leaving a song within 30 seconds counts as a skip — skipped songs come up less.")
                                bullet("No artist fills more than about a third of a mix.")
                                bullet("Each play of the Blend card reshuffles — the same history gives a fresh order.")
                                if taste.entriesWithDepth == 0 {
                                    hint("Skip tracking starts now: earlier plays are counted as full listens.")
                                }
                            }
                        }
                    }

                    section("Your data") {
                        HStack(spacing: 10) {
                            Button("Export…", action: exportProfile)
                            Button("Import…", action: importProfile)
                            Spacer()
                            Button("Reset…", role: .destructive) { confirmReset = true }
                        }
                        hint("\(env.player.playedEntries.count) plays on record. Export saves them as a JSON file you can inspect or move to another Mac.")
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 640)
        .background(Theme.Bg.base)
        .confirmationDialog("Reset your taste profile?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                env.player.replaceTasteHistory([])
                env.showToast("Taste profile reset")
            }
        } message: {
            Text("This clears your play history, top artists, Riff Blend, and the personal Home rails. Export first if you might want it back. This can't be undone.")
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, caption: String? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(Theme.Text.tertiary)
            if let caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.secondary)
            }
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(Theme.red)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chips(_ names: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(names, id: \.self) { n in
                Text(n)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
    }

    private func easeReason(_ a: TasteProfile.ArtistTaste, _ taste: TasteProfile) -> String {
        if taste.isFatigued(a.id) { return "On heavy rotation lately" }
        if let rate = a.skipRate { return "Skipped \(Int(rate * 100))% of the time" }
        return ""
    }

    // MARK: - Export / import

    private func exportProfile() {
        guard let data = try? TasteArchive.encode(env.player.playedEntries) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Riff Taste Profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            env.showToast("Taste profile exported")
        } catch {
            env.showToast("Couldn't save the file")
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try TasteArchive.decode(try Data(contentsOf: url))
            let before = env.player.playedEntries.count
            let merged = TasteArchive.merge(env.player.playedEntries, incoming)
            env.player.replaceTasteHistory(merged)
            let added = env.player.playedEntries.count - before
            env.showToast(added > 0 ? "Imported \(added) plays" : "Nothing new to import")
        } catch {
            env.showToast("That file isn't a Riff taste profile")
        }
    }
}
