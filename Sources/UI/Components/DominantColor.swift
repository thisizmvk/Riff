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
    private static var cache: [String: Color] = [:]

    /// Fetch + extract the accent color for `url`, or nil on failure.
    /// The fetch reuses `URLCache.shared` (same store AsyncImage
    /// warms), so on a cache hit this is near-instant.
    static func extract(from url: URL) async -> Color? {
        if let hit = cache[url.absoluteString] { return hit }
        var req = URLRequest(url: url)
        req.cachePolicy = .returnCacheDataElseLoad
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let image = NSImage(data: data) else { return nil }
        let color = Self.accentColor(from: image)
        if let color { cache[url.absoluteString] = color }
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
        return Color(red: picked.r, green: picked.g, blue: picked.b)
    }
}
