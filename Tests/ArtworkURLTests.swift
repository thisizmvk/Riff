import XCTest
@testable import Riff

/// `URL.upscaledArtwork(to:)` — the host-side size rewrite every
/// artwork display site goes through. The dangerous case is a URL
/// whose last `=` is NOT a size segment: rewriting ytimg's
/// `hqdefault.jpg?sqp=…&rs=…` corrupted the query string and blanked
/// every podcast/episode tile (field report 2026-10-20).
final class ArtworkURLTests: XCTestCase {

    private func up(_ s: String, _ size: Int = 448) -> String {
        URL(string: s)!.upscaledArtwork(to: size).absoluteString
    }

    func testRewritesGoogleusercontentSizeSegment() {
        XCTAssertEqual(
            up("https://lh3.googleusercontent.com/abc123=w120-h120-l90-rj"),
            "https://lh3.googleusercontent.com/abc123=w448-h448-l90-rj"
        )
    }

    func testRewritesGgphtSSizeSegment() {
        XCTAssertEqual(
            up("https://yt3.ggpht.com/xyz=s288-c-k-c0x00ffffff-no-rj"),
            "https://yt3.ggpht.com/xyz=w448-h448-l90-rj"
        )
    }

    func testLeavesYtimgQueryURLsAlone() {
        // The regression: last '=' sits inside the query string — a
        // rewrite here 404s the image.
        let raw = "https://i.ytimg.com/vi/abc/hqdefault.jpg?sqp=-oaymwEW&rs=AOn4CLB"
        XCTAssertEqual(up(raw), raw)
    }

    func testLeavesYtimgPathURLsAlone() {
        let raw = "https://i.ytimg.com/vi/abc/maxresdefault.jpg"
        XCTAssertEqual(up(raw), raw)
    }

    func testLeavesGoogleHostQueryURLsAlone() {
        // Even on a rewritable host, '=' belonging to a query param is
        // not a size segment.
        let raw = "https://lh3.googleusercontent.com/abc123?token=zzz"
        XCTAssertEqual(up(raw), raw)
    }

    func testLeavesNonSizeTrailingSegmentAlone() {
        // '=' followed by something that isn't a size spec.
        let raw = "https://lh3.googleusercontent.com/abc123=k9-no-rj"
        XCTAssertEqual(up(raw), raw)
    }

    func testLeavesOtherHostsAlone() {
        let raw = "https://example.com/art=w120-h120"
        XCTAssertEqual(up(raw), raw)
    }
}
