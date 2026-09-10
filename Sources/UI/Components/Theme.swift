import SwiftUI

/// Riff brand tokens. The single source of truth for color and spacing
/// constants used across the player and tile UIs. Inspired by YT Music
/// iOS — dark, generous spacing, bright red as the only chromatic accent.
enum Theme {
    /// Motion discipline: a small set of named animations so the app's
    /// transitions share one character (Apple-Music-like — fewer,
    /// slower, purposeful) instead of ad-hoc durations per view.
    /// Callers pass `nil` instead when Reduce Motion is on.
    enum Motion {
        /// Full-screen player open/close.
        static let panel = Animation.spring(response: 0.42, dampingFraction: 0.9)
        /// Rows shifting inside a list (queue advance, reorder).
        static let list = Animation.easeInOut(duration: 0.28)
        /// Small state changes (chips, badges, hover reveals).
        static let subtle = Animation.easeOut(duration: 0.18)
    }
    /// YouTube Music brand red. Used for the active play state, like
    /// buttons, primary CTAs.
    static let red = Color(red: 1.0, green: 0.0, blue: 0.2)

    static let surface = Color.white.opacity(0.04)
    static let surfaceHover = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.08)
}

extension Color {
    static let riffRed = Theme.red
}
