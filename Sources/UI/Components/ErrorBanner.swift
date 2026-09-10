import SwiftUI

/// Inline error banner shown when a tab's data load fails. Replaces the
/// silent `try?`-then-empty-state pattern so users can tell "broken" apart
/// from "genuinely empty".
///
/// Usage:
/// ```swift
/// if let error = errorMessage {
///     ErrorBanner(message: error) { Task { await load() } }
/// }
/// ```
struct ErrorBanner: View {
    let message: String
    let retry: (() -> Void)?

    init(message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Something went wrong")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.Fill.soft)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row)
                .stroke(Theme.red.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
    }
}

/// Maps a thrown error into a short user-facing message, and triggers
/// re-auth side effects when the error is `needsReauth`. Centralized so
/// every load site treats errors consistently.
@MainActor
enum LoadErrorPresenter {
    /// True for the cancellation a `.task(id:)` change or a newer
    /// keystroke produces (`URLSession` honours cooperative
    /// cancellation by THROWING `URLError.cancelled`). Callers return
    /// without touching state: the cancelled load's results are stale
    /// by definition and the replacement task owns the screen. Left
    /// unguarded, this wiped Search results and flashed "Network
    /// error: cancelled" on every keystroke that landed mid-request.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    static func message(for error: Error, env: AppEnvironment) -> String {
        if let inner = error as? InnerTubeClient.InnerTubeError {
            switch inner {
            case .needsReauth:
                // Side effect: surface the sign-in sheet so the user can
                // recover. Safe to call repeatedly — the binding is a Bool.
                env.isSignInSheetPresented = true
                return "Your session expired. Please sign in again."
            case .http(let code) where (500...599).contains(code):
                return "YouTube Music is having trouble (\(code)). Try again in a moment."
            case .http(let code):
                return "Request failed (HTTP \(code))."
            case .decoding:
                return "Couldn't read the response. YouTube may have changed their API — please update Riff."
            case .dataAPINotEnabled:
                return "Library access requires the YouTube Data API v3 to be enabled on your OAuth credentials."
            }
        }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            switch nsErr.code {
            case NSURLErrorNotConnectedToInternet:    return "You're offline."
            case NSURLErrorTimedOut:                  return "The request timed out. Check your connection."
            case NSURLErrorNetworkConnectionLost:     return "Network connection lost."
            default:                                  return "Network error: \(nsErr.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}
