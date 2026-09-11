import Foundation
import OSLog
import AppKit

/// One-shot diagnostics dump for bug reports. Collects Riff's own
/// os_log entries from THIS app session (notice level and above), the
/// MetricKit crash/hang payloads `DiagnosticsCenter` persisted over the
/// last 14 days, the played-history journal, and a small manifest of
/// app version + macOS version. The folder goes to ~/Downloads when the
/// sandbox allows it (needs `com.apple.security.files.downloads.read-write`),
/// otherwise to Application Support/Riff/diagnostic-exports inside the
/// app container — either way it is revealed in Finder.
///
/// Why "this session" only: a sandboxed third-party app can open
/// `OSLogStore` with `.currentProcessIdentifier` scope only (`.system`
/// needs admin rights or a logging entitlement), so lines from earlier
/// launches — including a run that crashed — are out of reach. The
/// MetricKit payloads are the cross-launch evidence: the OS delivers
/// them on a launch AFTER the crash or hang.
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
    enum ExportResult: Sendable {
        case success(URL)      // folder where the dump was written
        case failure(String)   // localized message
    }

    /// Run the dump end-to-end. All filesystem work and the OSLogStore
    /// scan (the slow part — ~1-2s on a busy log store) run on a
    /// detached utility-priority task so Settings and the player UI
    /// don't freeze; only the Finder reveal hops back to the main actor.
    static func exportDiagnostics() async -> ExportResult {
        let result = await Task.detached(priority: .utility) {
            DiagnosticsExporter.writeDump()
        }.value

        // 5. Reveal the folder in Finder so the user can attach it
        //    to a bug report in one gesture. AppKit — main actor.
        if case .success(let dumpDir) = result {
            NSWorkspace.shared.activateFileViewerSelecting([dumpDir])
        }
        return result
    }

    /// Off-main body of the export. `nonisolated` (like every writer
    /// below) so it can run on the detached task: it touches only
    /// FileManager, UserDefaults, Bundle/ProcessInfo and a local
    /// OSLogStore — no main-actor state.
    nonisolated private static func writeDump() -> ExportResult {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = df.string(from: Date())
        let dumpDir: URL
        do {
            dumpDir = try createDumpDirectory(named: "riff-diagnostics-\(stamp)")
        } catch {
            return .failure("Couldn't create diagnostics folder: \(error.localizedDescription)")
        }

        // 1. MetricKit crash/hang payloads. Copied first so the
        //    manifest can say how many rode along.
        let crashReportCount = copyCrashReports(
            into: dumpDir.appendingPathComponent("crash-reports", isDirectory: true)
        )

        // 2. Manifest: version + platform info so the reader knows
        //    what build produced the dump.
        writeManifest(to: dumpDir.appendingPathComponent("manifest.txt"),
                      crashReportCount: crashReportCount)

        // 3. os_log dump for this app session. OSLogStore does the
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

        // 4. Played history — plain JSON so a maintainer can eyeball
        //    the recent play sequence without loading the app.
        writePlayedHistorySnapshot(to: dumpDir.appendingPathComponent("played-history.json"))

        return .success(dumpDir)
    }

    // MARK: - Destination

    /// Create the dump folder. ~/Downloads first — that is what the
    /// Settings copy promises, and it works once the build carries
    /// `com.apple.security.files.downloads.read-write` (project.yml
    /// `entitlements.properties`). Riff is sandboxed: without that
    /// entitlement the write into ~/Downloads is denied, which used to
    /// fail the whole export. Fall back to Riff's Application Support
    /// folder, which the container always allows; the Finder reveal
    /// locates either one.
    nonisolated private static func createDumpDirectory(named name: String) throws -> URL {
        let fm = FileManager.default
        var parents: [URL] = []
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            parents.append(downloads)
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            parents.append(support.appendingPathComponent("Riff/diagnostic-exports", isDirectory: true))
        }
        var lastError: Error = CocoaError(.fileNoSuchFile)
        for parent in parents {
            let dir = parent.appendingPathComponent(name, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Writers

    /// Copy MetricKit diagnostic payloads (crashes, hangs, disk-write
    /// and CPU exceptions) from the last 14 days into `dest`. Source is
    /// where `DiagnosticsCenter` persists them:
    /// Application Support/Riff/diagnostics/diagnostic-<UTC>.json —
    /// keep this path in sync with `DiagnosticsCenter.folder`. Payloads
    /// hold call stacks, binary names/UUIDs and OS/app versions — no
    /// personal data, so the privacy bar above still holds. Returns how
    /// many files were copied; `dest` is only created when there is at
    /// least one.
    nonisolated private static func copyCrashReports(into dest: URL) -> Int {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return 0
        }
        let source = support.appendingPathComponent("Riff/diagnostics", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: source,
                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: [.skipsHiddenFiles]) else {
            return 0   // folder not created yet — no payload was ever delivered
        }
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        let recent = files.filter { url in
            guard url.lastPathComponent.hasPrefix("diagnostic-"), url.pathExtension == "json" else {
                return false
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (modified ?? Date.distantPast) >= cutoff
        }
        guard !recent.isEmpty else { return 0 }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            return 0
        }
        var copied = 0
        for file in recent {
            do {
                try fm.copyItem(at: file, to: dest.appendingPathComponent(file.lastPathComponent))
                copied += 1
            } catch {
                continue
            }
        }
        return copied
    }

    nonisolated private static func writeManifest(to url: URL, crashReportCount: Int) {
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
        lines.append("  riff.log             — Riff log entries (notice level and above) from THIS app")
        lines.append("                         session only; logs from earlier launches aren't readable")
        lines.append("                         from inside the sandbox")
        lines.append("  played-history.json  — timestamped playback journal (up to 500 items)")
        if crashReportCount > 0 {
            lines.append("  crash-reports/       — \(crashReportCount) MetricKit crash/hang payload(s) from the last")
            lines.append("                         14 days: call stacks, binary UUIDs, OS/app versions")
        } else {
            lines.append("  crash-reports/       — not included: no MetricKit crash/hang payloads in the last")
            lines.append("                         14 days (they arrive on a later launch, sometimes a day")
            lines.append("                         after the crash)")
        }
        lines.append("")
        lines.append("This dump contains no API keys, no OAuth tokens, and no cookies.")
        lines.append("played-history.json includes your listening history (track titles,")
        lines.append("artists, artwork URLs, and timestamps) — review before sharing.")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    nonisolated private static func writeOSLog(to url: URL) throws {
        // `.currentProcessIdentifier` is the only scope a sandboxed
        // third-party app can open (`.system` needs admin rights or a
        // logging entitlement), so this yields entries from THIS app
        // session only. A previous run that crashed is not reachable
        // here — its evidence is the MetricKit payload in crash-reports/.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        // Cap at the last 24 hours of the session. Longer windows blow
        // up the file for heavy listeners who leave Riff running for
        // days and rarely help diagnosis; if a maintainer needs more,
        // they can ask for a targeted re-dump.
        let cutoff = store.position(date: Date().addingTimeInterval(-24 * 60 * 60))
        // Filter to Riff's subsystem so we don't dump the thousands
        // of unrelated system-log lines. `dev.riff.app` matches
        // every Logger built with that subsystem across the app.
        let predicate = NSPredicate(format: "subsystem == %@", "dev.riff.app")
        let entries = try store.getEntries(at: cutoff, matching: predicate)
        // One formatter for the whole scan — ISO8601DateFormatter is
        // costly to build and this loop can visit thousands of entries.
        let timestampFormatter = ISO8601DateFormatter()
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
            let ts = timestampFormatter.string(from: logEntry.date)
            out.append("[\(ts)] [\(logEntry.category)] \(logEntry.composedMessage)")
        }
        if out.isEmpty {
            out.append("No Riff log entries at notice level or above in this app session yet (logs from earlier launches aren't included).")
        }
        try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static func writePlayedHistorySnapshot(to url: URL) {
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
