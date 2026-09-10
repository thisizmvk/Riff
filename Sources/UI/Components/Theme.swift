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
    // ── Palette "Graphite" — chosen in Riff Palette Studio, 2026-09-10 ──
    // Neutrals: hue 220°, chroma 6 %, base L 9, surface step +4.
    // Opaque SURFACES (`Bg`) are for things that sit on the app ground.
    // Translucent FILLS and TEXT tiers are for anything that may sit on
    // artwork or a blurred backdrop — they read correctly over any ground.
    enum Bg {
        /// The app ground. Near-black, cool: pure black flattened the
        /// artwork backdrops and made grey tiles float.
        static let base     = Color(red: 0.086, green: 0.086, blue: 0.094)   // #161618
        /// Mini bar, popovers, cards.
        static let elevated = Color(red: 0.122, green: 0.125, blue: 0.137)   // #1F2023
        /// Row / tile hover.
        static let hover    = Color(red: 0.161, green: 0.165, blue: 0.180)   // #292A2E
        /// Fields.
        static let sunken   = Color(red: 0.067, green: 0.067, blue: 0.075)   // #111113
    }
    enum Text {
        static let primary   = Color.white
        /// Subtitles, artists, durations. AA on every Bg.
        static let secondary = Color.white.opacity(0.86)
        /// Track numbers, eyebrows, hints. The floor for readable text.
        static let tertiary  = Color.white.opacity(0.62)
        static let disabled  = Color.white.opacity(0.38)
        static let onAccent  = Color.white
    }
    /// Translucent fills, in four steps. Use over artwork / blur; use
    /// `Bg` when the thing is an opaque surface.
    enum Fill {
        static let faint  = Color.white.opacity(0.04)
        static let soft   = Color.white.opacity(0.06)
        static let medium = Color.white.opacity(0.10)
        static let strong = Color.white.opacity(0.16)
    }
    /// The one chromatic accent: play state, likes, primary CTAs. Not
    /// for selection — see `Selected`.
    enum Accent {
        static let brand   = Color(red: 0.965, green: 0.118, blue: 0.231)   // #F61E3B
        static let hover   = Color(red: 0.969, green: 0.231, blue: 0.329)   // #F73B54
        static let pressed = Color(red: 0.922, green: 0.039, blue: 0.157)   // #EB0A28
    }
    enum Line {
        static let hairline = Color.white.opacity(0.08)
        static let strong   = Color.white.opacity(0.16)
    }
    /// Chips and segmented controls: neutral (white on ground), so the
    /// accent keeps its meaning.
    enum Selected {
        static let fill = Color.white
        static let text = Bg.base
    }
    enum Radius {
        static let tile: CGFloat = 12
        static let card: CGFloat = 10
        static let row: CGFloat = 8
        static let thumb: CGFloat = 6
    }
    /// Legacy aliases — the names the existing call sites use.
    static let red = Accent.brand
    static let surface = Fill.faint
    static let surfaceHover = Fill.medium
    static let divider = Line.hairline
}

extension Color {
    static let riffRed = Theme.red
}
