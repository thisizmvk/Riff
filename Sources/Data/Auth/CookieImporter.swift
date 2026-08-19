import Foundation

/// Parses a pasted cookie blob into name→value pairs. Kept free of
/// any networking or cookie-store writes so it unit-tests cleanly and
/// so the parsing logic has one obvious home. The actual store writes
/// live in `CookieJar`.
enum CookieImporter {
    /// Tolerates the `Cookie:` header form (semicolon-separated) and
    /// newline-separated `name=value` pairs. Skips blank fragments
    /// and anything without an `=`.
    static func parse(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        let normalized = raw.replacingOccurrences(of: "\n", with: ";")
        for fragment in normalized.split(separator: ";") {
            let trimmed = fragment.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !val.isEmpty else { continue }
            out[key] = val
        }
        return out
    }

    /// True when the parsed set contains a cookie usable for
    /// SAPISIDHASH authentication. Without one, an import can't
    /// produce a working session.
    static func hasAuthCookie(_ pairs: [String: String]) -> Bool {
        pairs.keys.contains("SAPISID") || pairs.keys.contains("__Secure-3PAPISID")
    }
}
