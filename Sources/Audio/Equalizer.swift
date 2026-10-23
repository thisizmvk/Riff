import Foundation

/// 10-band equalizer model. The DSP lives in `player-bridge.js` (Web Audio
/// BiquadFilters in the page's audio graph); this is just the bands, the
/// presets, and the JS payload. Pure, so it's harness-testable.
enum Equalizer {
    /// Band centers in Hz — matches `EQ_FREQS` in player-bridge.js.
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let range: ClosedRange<Double> = -12...12

    struct Preset: Identifiable, Hashable, Sendable {
        let name: String
        let gains: [Double]
        var id: String { name }
    }

    static let flat = Preset(name: "Flat", gains: Array(repeating: 0, count: 10))

    static let presets: [Preset] = [
        flat,
        Preset(name: "Bass Boost",     gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass Reducer",   gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Treble Boost",   gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        Preset(name: "Treble Reducer", gains: [0, 0, 0, 0, 0, -1, -2, -4, -5, -6]),
        Preset(name: "Vocal",          gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        Preset(name: "Acoustic",       gains: [3, 3, 2, 1, 1, 1, 2, 3, 3, 2]),
        Preset(name: "Electronic",     gains: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        Preset(name: "Hip-Hop",        gains: [5, 4, 2, 3, -1, -1, 1, -1, 2, 3]),
        Preset(name: "Rock",           gains: [4, 3, 2, 1, -1, -1, 1, 2, 3, 4]),
        Preset(name: "Pop",            gains: [-1, 0, 1, 3, 4, 3, 1, 0, -1, -1]),
        Preset(name: "Classical",      gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        Preset(name: "Late Night",     gains: [3, 2, 1, 0, -1, -1, 0, 1, 2, 2]),
        Preset(name: "Small Speakers", gains: [5, 4, 3, 2, 1, 0, 0, 0, -1, -2]),
    ]

    /// Clamp to range, snap to 0.5 dB, and always exactly 10 bands.
    static func normalized(_ gains: [Double]) -> [Double] {
        (0..<frequencies.count).map { i in
            let g = i < gains.count && gains[i].isFinite ? gains[i] : 0
            return (min(max(g, range.lowerBound), range.upperBound) * 2).rounded() / 2
        }
    }

    /// The preset these gains exactly match, else nil ("Custom").
    static func matchingPreset(_ gains: [Double]) -> Preset? {
        let g = normalized(gains)
        return presets.first { $0.gains == g }
    }

    /// JS argument for `musicBridge.setEQ(...)`: a 10-number array, or
    /// `null` when off or flat (the page then builds no graph at all).
    static func jsArgument(enabled: Bool, gains: [Double]) -> String {
        let g = normalized(gains)
        guard enabled, g.contains(where: { $0 != 0 }) else { return "null" }
        return "[" + g.map { String(format: "%.1f", $0) }.joined(separator: ",") + "]"
    }

    /// "32" / "1K" / "16K" axis labels.
    static func label(for hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))K" : "\(Int(hz))"
    }
}
