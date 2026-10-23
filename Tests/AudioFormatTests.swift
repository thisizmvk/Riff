import XCTest
@testable import Riff

/// `HiddenPlayerWebView.AudioFormat` — what the Now Playing quality badge
/// claims. The badge must never overstate: "below best" only when the
/// page was offered a meaningfully better format.
final class AudioFormatTests: XCTestCase {

    private func fmt(codec: String? = "opus", bitrate: Int? = 138_000,
                     bestCodec: String? = "aac", bestBitrate: Int? = 255_000) -> HiddenPlayerWebView.AudioFormat {
        .init(itag: 251, codec: codec, bitrate: bitrate, audioQuality: nil,
              bestItag: 141, bestBitrate: bestBitrate, bestCodec: bestCodec, videoHeight: 0)
    }

    func testLabelFormatsCodecAndKbps() {
        XCTAssertEqual(fmt().label, "Opus · 138 kbps")
        XCTAssertEqual(fmt().bestLabel, "AAC · 255 kbps")
    }

    func testLabelDegradesGracefully() {
        XCTAssertEqual(fmt(bitrate: nil).label, "Opus")
        XCTAssertEqual(fmt(codec: nil).label, "138 kbps")
        XCTAssertNil(fmt(codec: nil, bitrate: nil).label)
    }

    func testBelowBestNeedsAMeaningfulGap() {
        XCTAssertTrue(fmt(bitrate: 138_000, bestBitrate: 255_000).isBelowBestAvailable)
        // Within 15% is the same tier — don't nag.
        XCTAssertFalse(fmt(bitrate: 150_000, bestBitrate: 160_000).isBelowBestAvailable)
        // Already on the best.
        XCTAssertFalse(fmt(bitrate: 255_000, bestBitrate: 255_000).isBelowBestAvailable)
        // Unknown current bitrate never claims "below best".
        XCTAssertFalse(fmt(bitrate: nil).isBelowBestAvailable)
    }
}
