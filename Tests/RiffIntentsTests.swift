import XCTest
@testable import Riff

/// Tests for the pure helpers in `Sources/Intents/RiffIntents.swift`.
/// The `perform()` bodies touch `AppEnvironment.current` + network, so
/// they aren't unit-testable without a much heavier harness — we cover
/// the only inspectable policy that affects user behavior: the artist-
/// vs-genre similarity gate that drives `OpenStationForIntent`'s
/// fallback decision.
final class RiffIntentsTests: XCTestCase {

    // Equal strings are always similar.
    func testNamesSimilarOnEqual() {
        XCTAssertTrue(OpenStationForIntent.namesAreSimilar("daft punk", "daft punk"))
    }

    // Substring containment is enough — search results often append a
    // disambiguator like "(Artist)" or "VEVO" to the YT title.
    func testNamesSimilarOnSubstring() {
        XCTAssertTrue(OpenStationForIntent.namesAreSimilar("the beatles", "beatles"))
        XCTAssertTrue(OpenStationForIntent.namesAreSimilar("daft punk", "daft punk official"))
    }

    // Genre keywords should NOT pull a random-named artist hit through.
    // "Synthwave" alone should not match an artist titled "Synthwave Joe"
    // strongly enough to skip the genre-radio fallback path.
    func testNamesSimilarRejectsLowJaccardOverlap() {
        // "synthwave" vs "synthwave joe": substring rule fires (the
        // shorter is contained in the longer). This is by design — if
        // YT's top artist hit for "synthwave" is literally called
        // "Synthwave Joe", the user probably DID mean that artist.
        // The contract we're guarding is the inverse case: an unrelated
        // artist with zero word overlap should NOT be considered similar.
        XCTAssertFalse(OpenStationForIntent.namesAreSimilar("lo-fi hip hop", "the weeknd"))
        XCTAssertFalse(OpenStationForIntent.namesAreSimilar("focus", "metallica"))
    }

    // Jaccard overlap ≥ 0.5 is the cutoff. "John Mayer Trio" vs
    // "John Mayer" → intersection {john, mayer} = 2, union {john, mayer,
    // trio} = 3 → 2/3 ≈ 0.667, similar.
    func testNamesSimilarOnHighJaccardOverlap() {
        XCTAssertTrue(OpenStationForIntent.namesAreSimilar("john mayer trio", "john mayer"))
    }

    // Empty inputs are handled (set-overlap denominator is zero) —
    // they must NOT crash and must NOT report similar.
    func testNamesSimilarHandlesEmptyInputs() {
        // Identical (even identically empty) strings are equal → similar.
        XCTAssertTrue(OpenStationForIntent.namesAreSimilar("", ""))
        // Mixed empty/non-empty is NOT similar: Swift's
        // `contains("")` is false, so the substring rule does not
        // fire, and the token-set guard rejects an empty side. (The
        // earlier expectation of `true` documented a substring
        // behavior Swift never had.)
        XCTAssertFalse(OpenStationForIntent.namesAreSimilar("artist", ""))
        XCTAssertFalse(OpenStationForIntent.namesAreSimilar("", "artist"))
    }

    // Single-character non-letter tokens are stripped — punctuation
    // and stylization shouldn't break similarity. "A.C.E" vs "ace" →
    // letter-only tokens {a, c, e} vs {ace} share zero, but the substring
    // rule on the raw string ("ace" not in "a.c.e") doesn't fire either.
    // This is a known limitation — document via a regression test.
    func testNamesSimilarPunctuationKnownLimitation() {
        XCTAssertFalse(OpenStationForIntent.namesAreSimilar("a.c.e", "ace"))
    }
}
