import SwiftUI
import AppKit

/// Extracts a representative accent color from album artwork for the
/// adaptive Now Playing backdrop (Apple Music's signature look).
/// Pure-local: downsamples the image and picks the most vivid,
/// non-extreme color so the tint reads as "this album" without going
/// muddy (average color) or blinding (raw brightest pixel).
///
/// Results are cached by image URL so re-opening the same track
/// doesn't re-sample. The sampling runs off the main actor.
enum DominantColor {
    /// Bounded, MainActor-isolated cache. MainActor (not a bare static
    /// var mutated from a nonisolated async function — a latent data
    /// race under strict concurrency); capped so a long session can't
    /// grow it unboundedly — insertion order approximates LRU well
    /// enough for artwork accents.
    @MainActor private static var cache: [String: Color] = [:]
    @MainActor private static var cacheOrder: [String] = []
    private static let cacheCap = 200

    /// Fetch + extract the accent color for `url`, or nil on failure.
    /// The fetch reuses `URLCache.shared` (same store AsyncImage
    /// warms), so on a cache hit this is near-instant.
    static func extract(from url: URL) async -> Color? {
        if let hit = await MainActor.run(body: { cache[url.absoluteString] }) { return hit }
        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let image = NSImage(data: data) else { return nil }
        let color = Self.accentColor(from: image)
        if let color {
            await MainActor.run {
                if cache[url.absoluteString] == nil {
                    cacheOrder.append(url.absoluteString)
                    if cacheOrder.count > cacheCap {
                        let evicted = cacheOrder.removeFirst()
                        cache.removeValue(forKey: evicted)
                    }
                }
                cache[url.absoluteString] = color
            }
        }
        return color
    }

    /// Downsample to a small grid and pick the color with the best
    /// "vividness" score = saturation × mid-weighted brightness.
    /// Rejects near-black / near-white / near-gray so the backdrop
    /// always has some hue to it.
    private static func accentColor(from image: NSImage) -> Color? {
        let side = 32
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
        guard let ctx = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var best: (score: Double, r: Double, g: Double, b: Double)? = nil
        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0
            let maxC = max(r, g, b), minC = min(r, g, b)
            let brightness = maxC
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            // Skip near-black, near-white, near-gray.
            if brightness < 0.15 || brightness > 0.95 || saturation < 0.15 { continue }
            // Favour vivid mid-bright colors: peaks around brightness 0.6.
            let midWeight = 1.0 - abs(brightness - 0.6)
            let score = saturation * midWeight
            if best == nil || score > best!.score {
                best = (score, r, g, b)
            }
        }
        guard let picked = best else { return nil }
        // Grade the raw vivid pixel into a tone that blends over the dark
        // graphite UI instead of reading as an electric hue. The single
        // most-vivid pixel is often fully saturated and bright; washing
        // the app in that looks "off". Pull saturation and brightness
        // into a mid band so the tint keeps its hue but grades softly.
        let raw = NSColor(srgbRed: picked.r, green: picked.g, blue: picked.b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        raw.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let gradedS = min(s, 0.58)            // cap neon saturation
        let gradedV = min(max(v, 0.42), 0.70) // hold a mid brightness
        return Color(hue: Double(h), saturation: Double(gradedS), brightness: Double(gradedV))
    }
}
