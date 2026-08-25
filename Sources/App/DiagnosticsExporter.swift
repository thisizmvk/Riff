import Foundation
import OSLog
import AppKit

/// One-shot diagnostics dump for bug reports. Pulls the last 24 h of
/// os_log entries for Riff's subsystem, includes the played-history
/// journal + a small manifest of app version + macOS version, and
/// drops the folder in ~/Downloads.
///
/// **What we deliberately DON'T include:**
///   - The user's Keychain (API keys, OAuth tokens, scrobble session keys).
///   - The full YT cookie jar.
///   - The `Sources/*.plist` bundle metadata.
///   - Any snapshot of the WKWebView's DOM.
///
/// The bar: a Riff maintainer should be able to read the dump and
/// reproduce/diagnose a playback issue WITHOUT any sensitive data
/// crossing hands. If we ever need cookies for repro, the user
/// provides them separately.
@MainActor
enum DiagnosticsExporter {
    /// Result surfaced by the Settings button after export runs.
    enum ExportResult {
        case success(URL)      // folder where the dump was written
        case failure(String)   // localized message
    }

    /// Run the dump end-to-end. Returns quickly (all synchronous
    /// filesystem work); log queries are the slow part and can take
    /// ~1-2s on a busy log store.
    static func exportDiagnostics() async -> ExportResult {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = df.string(from: Date())
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let downloadsDir else {
            return .failure("Couldn't reach ~/Downloads.")
        }
        let dumpDir = downloadsDir.appendingPathComponent("riff-diagnostics-\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        } catch {
            return .failure("Couldn't create diagnostics folder: \(error.localizedDescription)")
        }

        // 1. Manifest: version + platform info so the reader knows
        //    what build produced the dump.
        writeManifest(to: dumpDir.appendingPathComponent("manifest.txt"))

        // 2. os_log dump for the last 24 h. OSLogStore does the
        //    heavy lifting; we filter by subsystem to skip the
        //    thousands of unrelated system log lines that would
        //    make the dump unreadable.
        do {
            try writeOSLog(to: dumpDir.appendingPathComponent("riff.log"))
        } catch {
            // Non-fatal — write a stub so the user knows the log
            // step failed but the rest of the dump lands.
            let msg = "os_log dump failed: \(error.localizedDescription)\n"
            try? msg.write(to: dumpDir.appendingPathComponent("riff.log"), atomically: true, encoding: .utf8)
        }

        // 3. Played history — plain JSON so a maintainer can eyeball
        //    the recent play sequence without loading the app.
        writePlayedHistorySnapshot(to: dumpDir.appendingPathComponent("played-history.json"))

        // 4. Reveal the folder in Finder so the user can attach it
        //    to a bug report in one gesture.
        NSWorkspace.shared.activateFileViewerSelecting([dumpDir])

        return .success(dumpDir)
    }

    // MARK: - Writers

    private static func writeManifest(to url: URL) {
        var lines: [String] = []
        lines.append("Riff diagnostics dump")
        lines.append("Generated: \(Date())")
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("Riff version: \(bundleVersion) (\(build))")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("Host arch: \(hostArch)")
        lines.append("")
        lines.append("Contents:")
        lines.append("  manifest.txt         — this file")
        lines.append("  riff.log             — os_log entries from the last 24 hours (Riff subsystem only)")
        lines.append("  played-history.json  — timestamped playback journal (up to 500 items)")
        lines.append("")
        lines.append("This dump contains no API keys, no OAuth tokens, and no cookies.")
        lines.append("played-history.json includes your listening history (track titles,")
        lines.append("artists, artwork URLs, and timestamps) — review before sharing.")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func writeOSLog(to url: URL) throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        // Last 24 hours. Longer windows blow up the file for
        // heavy-listener users and rarely help diagnosis; if a
        // maintainer needs more, they can ask for a targeted
        // re-dump.
        let cutoff = store.position(date: Date().addingTimeInterval(-24 * 60 * 60))
        // Filter to Riff's subsystem so we don't dump the thousands
        // of unrelated system-log lines. `dev.riff.app` matches
        // every Logger built with that subsystem across the app.
        let predicate = NSPredicate(format: "subsystem == %@", "dev.riff.app")
        let entries = try store.getEntries(at: cutoff, matching: predicate)
        var out: [String] = []
        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            // SECURITY: exclude debug/info-level lines. Whether the
            // OSLogStore persists them is environment-dependent, and
            // debug lines are exactly where verbose bodies (event
            // payloads, response previews) live — the manifest promises
            // this dump carries no secrets, so only notice+ may ride.
            switch logEntry.level {
            case .notice, .error, .fault: break
            default: continue
            }
            let ts = ISO8601DateFormatter().string(from: logEntry.date)
            out.append("[\(ts)] [\(logEntry.category)] \(logEntry.composedMessage)")
        }
        if out.isEmpty {
            out.append("No Riff log entries in the last 24 hours.")
        }
        try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writePlayedHistorySnapshot(to url: URL) {
        // Read directly from the persisted journal rather than the
        // in-memory copy, so the dump reflects what would survive
        // a relaunch. Same key + shape PlayedHistoryStore writes.
        guard let data = UserDefaults.standard.data(forKey: "player.history.v3") else {
            let stub = "[]"
            try? stub.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        // Re-encode pretty so the JSON is human-readable in the dump.
        if let decoded = try? JSONDecoder().decode([PlayedEntry].self, from: data) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let pretty = try? encoder.encode(decoded) {
                try? pretty.write(to: url, options: .atomic)
                return
            }
        }
        // Fallback: write the raw bytes if pretty-decode failed.
        try? data.write(to: url, options: .atomic)
    }
}
