import Foundation
import os

/// Unified-log Loggers per area. Using `os.Logger` instead of `print()` so
/// log lines reach macOS's unified logging system — visible in Xcode's
/// console *and* readable from the terminal via:
///
///     log show --predicate 'subsystem == "dev.riff.app"' --last 5m
///
/// which lets us iterate on bugs without staring at the Xcode UI. All
/// loggers share `dev.riff.app` as the subsystem; categories carve up the
/// surface so we can grep them independently.
enum Log {
    static let bridge   = Logger(subsystem: "dev.riff.app", category: "bridge")
    static let oauth    = Logger(subsystem: "dev.riff.app", category: "oauth")
    static let innertube = Logger(subsystem: "dev.riff.app", category: "innertube")
    static let resolver = Logger(subsystem: "dev.riff.app", category: "resolver")
}

/// Queue-core audit journal. `note(_:)` does two things at once:
///
///   1. Logs the line at `.notice` on `Log.bridge`, so it shows up in a
///      live `log stream --level debug` capture (same lines the field
///      workflow has always graded) AND survives `DiagnosticsExporter`'s
///      notice-and-above OSLogStore filter.
///   2. Appends it to an in-memory ring that `DiagnosticsExporter`
///      writes out verbatim as `bridge-journal.log` — the artifact
///      `tools/harness/fieldcheck.sh` can grade without the user having
///      had a `log stream` running when the bug happened.
///
/// Ring lines use the exporter's format — `[<ISO8601>] [bridge] <line>`
/// — so fieldcheck's substring greps work on either source unchanged.
///
/// PRIVACY BAR: audit lines carry video/playlist ids and verdict labels
/// ONLY — never track titles, search queries, or any other user
/// content. The journal rides in diagnostics exports that users attach
/// to public bug reports; anything richer than an id must stay in a
/// plain `Log.bridge.debug` line with `privacy: .private`.
@MainActor
enum Audit {
    /// Newest-last journal lines, capped at `maxLines` (oldest dropped).
    private(set) static var ring: [String] = []
    private static let maxLines = 2000
    /// One formatter for the life of the app — ISO8601DateFormatter is
    /// costly to build and some audit sites fire per snapshot tick.
    private static let timestampFormatter = ISO8601DateFormatter()

    static func note(_ line: String) {
        Log.bridge.notice("\(line, privacy: .public)")
        ring.append("[\(timestampFormatter.string(from: Date()))] [bridge] \(line)")
        if ring.count > maxLines {
            ring.removeFirst(ring.count - maxLines)
        }
    }
}
