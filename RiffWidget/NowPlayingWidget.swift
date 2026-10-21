import WidgetKit
import SwiftUI
import AppIntents

// macOS Notification Center widget for Riff. Shows artwork + title +
// transport controls. Reads from the App-Group-shared
// NowPlayingSnapshot written by the host app on every track change.
//
// Sizes supported:
//   • systemSmall — square artwork tile with overlaid title/subtitle
//     and a single play/pause button. Tapping the tile opens Riff.
//   • systemMedium — artwork on the left, title + subtitle + a full
//     transport row [previous / play-pause / next] on the right.
//
// Transport buttons trigger AppIntents that enqueue a command into
// the shared App Group defaults. The host app drains the queue when
// it foregrounds [openAppWhenRun=true brings it forward], at which
// point PlayerBridge actually executes the command.

struct NowPlayingWidget: Widget {
    let kind: String = NowPlayingWidgetIdentifier.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Riff — Now Playing")
        .description("Artwork, title, and transport for the current Riff track.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Timeline

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: Date(), snapshot: NowPlayingSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // We don't know when the host will next change tracks — the
        // host's WidgetCenter.reloadTimelines call from the writer is
        // the real driver. As a fallback, refresh in ~30s so the
        // widget catches up if reload notifications were missed.
        let now = Date()
        let entry = NowPlayingEntry(date: now, snapshot: NowPlayingSnapshotStore.read())
        let refresh = now.addingTimeInterval(30)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

// MARK: - View

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: smallBody
        default: mediumBody
        }
    }

    private var smallBody: some View {
        ZStack(alignment: .bottomLeading) {
            artwork
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snapshot?.title ?? "Not playing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(entry.snapshot?.subtitle ?? "Open Riff to start a track")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(8)
        }
        .widgetURL(URL(string: "riff://nowplaying"))
    }

    private var mediumBody: some View {
        HStack(spacing: 12) {
            artwork
                .aspectRatio(1, contentMode: .fit)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.snapshot?.title ?? "Not playing")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.snapshot?.subtitle ?? "Open Riff to start")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                transportRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = artworkFileURL(),
           let data = try? Data(contentsOf: url),
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
        } else {
            ZStack {
                Rectangle()
                    .fill(.fill.secondary)
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transportRow: some View {
        HStack(spacing: 14) {
            Button(intent: WidgetPreviousIntent()) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)
            .disabled(entry.snapshot == nil)

            Button(intent: WidgetTogglePlayIntent()) {
                Image(systemName: (entry.snapshot?.isPlaying ?? false)
                      ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)

            Button(intent: WidgetSkipNextIntent()) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            .disabled(entry.snapshot == nil)
        }
        .foregroundStyle(.primary)
    }

    // Resolve the cached artwork JPG the host writes into the shared
    // App Group container. We deliberately read the file synchronously
    // here — widget render passes are short and the file is tiny
    // [pre-resized to 256x256, JPG]. Returns nil when no track is
    // loaded yet or when the host hasn't cached anything; the
    // placeholder branch handles that case.
    private func artworkFileURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NowPlayingSnapshotStore.appGroupID)
        else { return nil }
        let path = container
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent("current.jpg", isDirectory: false)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }
}

// MARK: - Previews

// Xcode Canvas previews — render the widget at both supported families
// with a populated snapshot AND the empty placeholder, so design changes
// can be verified without launching WidgetKit Simulator (which trips on
// AppIntents/App-Group widgets) or installing into Notification Center.
#Preview("Small — playing", as: .systemSmall) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry(
        date: .now,
        snapshot: NowPlayingSnapshot(
            videoId: "preview",
            title: "Karuppu",
            subtitle: "Sai Abhyankkar",
            thumbnailURLString: nil,
            isPlaying: true,
            updatedAt: .now,
            elapsed: 42,
            duration: 213
        )
    )
}

#Preview("Medium — playing", as: .systemMedium) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry(
        date: .now,
        snapshot: NowPlayingSnapshot(
            videoId: "preview",
            title: "Rama Rama Krishna Krishna",
            subtitle: "M.M. Keeravani",
            thumbnailURLString: nil,
            isPlaying: false,
            updatedAt: .now,
            elapsed: 108,
            duration: 244
        )
    )
}

#Preview("Small — placeholder", as: .systemSmall) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry(date: .now, snapshot: nil)
}
