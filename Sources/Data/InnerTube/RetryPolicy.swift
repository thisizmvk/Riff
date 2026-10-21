import Foundation

/// Pure decision table for retrying a failed InnerTube request.
/// Tested by `tools/harness/run.sh` (section "RetryPolicy").
///
/// Scope — deliberately narrow:
///   - Idempotent READS only (`search`, `browse`, `next`, `player`,
///     `accountMenu`, `searchSuggestions`). Mutations (like, subscribe,
///     playlist edits, …) are NEVER retried: a retry after an
///     ambiguous failure could apply the mutation twice.
///   - At most ONE retry per request (`attempt >= 2` → nil).
///   - Only fast-fail signals are retried: 429 / 502 / 503 / 504 and
///     `.networkConnectionLost` / `.cannotConnectToHost` /
///     `.dnsLookupFailed`. `.timedOut` is NOT retried — the session's
///     10 s `timeoutIntervalForRequest` budget is already spent, and
///     `browseHome` chains several sequential `/browse` calls, so a
///     timeout retry would compound into a 20 s+ foreground stall.
///     `.notConnectedToInternet` and `.cancelled` are never retried
///     (offline won't heal in a second; cancellation means a
///     supersing caller already moved on). 500 is left out: for
///     InnerTube it is usually deterministic (bad params/body).
///   - `Retry-After` is honoured in its delta-seconds form only,
///     capped at `retryAfterCap` (3 s) — beyond the cap we surface
///     the error instead of sitting silently in a spinner. An
///     HTTP-date (or garbage) header is treated as "no hint".
///
/// The endpoint gate is a `switch` with no `default` on purpose: any
/// new `Endpoint` case forces an explicit idempotency decision here
/// at compile time.
enum RetryPolicy {

    /// Longest server-hinted wait we will honour. Above this, give up
    /// and surface the error (a search sitting silently for 10 s is
    /// worse than a banner).
    static let retryAfterCap: TimeInterval = 3

    /// Delay (seconds) before retrying the failed attempt, or nil for
    /// "do not retry — rethrow the error".
    ///
    /// - Parameters:
    ///   - endpoint: which InnerTube endpoint failed.
    ///   - attempt: 1-based number of the attempt that just failed.
    ///     Only attempt 1 may be retried (max one retry).
    ///   - status: HTTP status code, when the failure was a non-2xx
    ///     response. Pass nil for transport errors.
    ///   - urlError: `URLError.code`, when the failure was thrown by
    ///     URLSession before any response arrived. Pass nil otherwise.
    ///   - retryAfter: raw `Retry-After` header value, if present.
    ///   - unit: jitter source in `0..<1`; injectable so the harness
    ///     can pin exact delays. Defaults to `Double.random`.
    static func delay(endpoint: Endpoint,
                      attempt: Int,
                      status: Int?,
                      urlError: URLError.Code?,
                      retryAfter: String?,
                      unit: Double = Double.random(in: 0..<1)) -> TimeInterval? {
        // Max one retry.
        guard attempt < 2 else { return nil }

        // Idempotency gate. No `default:` — a new Endpoint case must
        // be classified here before the project compiles.
        switch endpoint {
        case .search, .browse, .next, .player, .accountMenu, .searchSuggestions:
            break  // idempotent reads — retry candidates
        case .like, .dislike, .removeLike, .editPlaylist,
             .createPlaylist, .deletePlaylist, .subscribe, .unsubscribe:
            return nil  // mutations — never retried
        }

        // Transport-level failures (no HTTP response at all).
        if let code = urlError {
            switch code {
            case .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
                return jitter(unit)
            case .cancelled, .timedOut, .notConnectedToInternet:
                return nil
            default:
                return nil
            }
        }

        // HTTP-level failures.
        guard let status = status else { return nil }
        switch status {
        case 429:
            if let hinted = parseRetryAfterSeconds(retryAfter) {
                return hinted <= retryAfterCap ? hinted : nil
            }
            return jitter(unit)  // 429 without a usable hint
        case 502, 503, 504:
            return jitter(unit)
        default:
            return nil  // 401/403 (needsReauth), 500, 4xx, everything else
        }
    }

    /// Parse a `Retry-After` header's delta-seconds form ("2", " 10 ").
    /// The HTTP-date form (and anything else non-numeric or negative)
    /// returns nil — treated by `delay` as "no hint".
    static func parseRetryAfterSeconds(_ raw: String?) -> TimeInterval? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let seconds = Int(trimmed), seconds >= 0 else { return nil }
        return TimeInterval(seconds)
    }

    /// Jittered short backoff: 0.3–0.9 s. `unit` is clamped defensively.
    private static func jitter(_ unit: Double) -> TimeInterval {
        let clamped: Double = min(max(unit, 0.0), 1.0)
        return 0.3 + clamped * 0.6
    }
}
