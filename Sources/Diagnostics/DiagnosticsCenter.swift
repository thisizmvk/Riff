import Foundation
import os
#if canImport(MetricKit)
import MetricKit
#endif

/// Apple's `MetricKit` is the built-in crash + hang + perf reporter for
/// macOS 12+. We subscribe at app start; the OS hands us aggregated
/// payloads roughly daily (the system delivers them when convenient,
/// usually on app launch) describing crashes, hangs, disk-write
/// exceptions, and CPU-exception events from the *previous* session.
///
/// Riff's policy: write every payload as JSON under
/// `~/Library/Application Support/Riff/diagnostics/<UTC>.json`. We
/// don't network anything by default — privacy stays intact and the
/// user can read / share the file manually (or we can add an opt-in
/// uploader later). This is enough to catch YT-protocol-break-induced
/// crashes that would otherwise silently lose a user.
///
/// The class is `@MainActor` because `MXMetricManager.shared` is
/// thread-confined and we add ourselves as a subscriber from the main
/// actor; payload delivery itself can hop background threads, so we
/// `dispatch async` back to a fileIO queue for the actual write.
@MainActor
final class DiagnosticsCenter: NSObject {
    static let shared = DiagnosticsCenter()

    private let fileIO = DispatchQueue(label: "dev.riff.diagnostics", qos: .utility)
    private let log = Logger(subsystem: "dev.riff.app", category: "diagnostics")

    /// Folder we write payloads into. Created lazily on first write.
    private lazy var folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let url = support.appendingPathComponent("Riff/diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Subscribe to MetricKit. Idempotent — calling start() twice is
    /// safe; the second call is a no-op because `MXMetricManager`
    /// dedupes subscribers. Call once at app launch.
    func start() {
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        log.debug("MetricKit subscriber registered")
        #else
        log.debug("MetricKit unavailable on this platform; crash reporter disabled")
        #endif
    }
}

#if canImport(MetricKit)
extension DiagnosticsCenter: MXMetricManagerSubscriber {
    // Note: `MXMetricPayload` is iOS-only — Apple does not ship it on
    // macOS as of the macOS 15.5 SDK (the runner image), even though
    // `MXMetricManagerSubscriber` is available. The macOS subscriber
    // only receives diagnostic payloads, which is fine for our use:
    // crashes / hangs / disk-write exceptions are what we actually
    // want to catch. CPU/memory perf metrics aren't surfaced to
    // third-party macOS apps via this API.

    /// Diagnostic payloads — crashes, hangs, disk-write exceptions,
    /// CPU-exception events. The high-signal channel; this is what
    /// flags YT-protocol regressions that cause crashes.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            persist(prefix: "diagnostic", json: p.jsonRepresentation())
        }
    }

    /// Write `<prefix>-<UTC ISO8601>.json` to the diagnostics folder.
    /// Hops to a fileIO queue so we don't block the MetricKit delivery
    /// thread and so the main actor isn't involved in disk I/O.
    nonisolated private func persist(prefix: String, json: Data) {
        Task { @MainActor in
            let folder = self.folder
            let log = self.log
            self.fileIO.async {
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let stamp = fmt.string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let url = folder.appendingPathComponent("\(prefix)-\(stamp).json")
                do {
                    try json.write(to: url, options: .atomic)
                    log.debug("wrote \(url.path, privacy: .public)")
                } catch {
                    log.error("failed to write \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
#endif
