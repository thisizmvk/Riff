import XCTest
@testable import Riff

/// Fixture-based tests for `InnerTubeClient`'s renderer-walking parsers.
///
/// The fixtures are hand-crafted minimal JSON dictionaries that mimic
/// the shape YT Music actually returns — small enough to inspect at a
/// glance, structured enough that a real protocol break (renderer key
/// rename, navigation-endpoint reshape) trips a test failure.
///
/// We test the static parser entrypoints directly (`parseListItem`,
/// `parseTwoRowItem`, `parseHomeShelf`, `endpointToIdKind`) rather
/// than going through `URLSession` — there's no value in mocking
/// the network for tests that exist to detect renderer drift.
final class InnerTubeParserTests: XCTestCase {

    // MARK: - endpointToIdKind

    func testWatchEndpointMapsToSong() {
        let endpoint: [String: Any] = ["watchEndpoint": ["videoId": "abc123"]]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "abc123")
        XCTAssertEqual(resolved?.1, .song)
    }

    func testBrowseEndpointAlbumPageType() {
        let endpoint: [String: Any] = [
            "browseEndpoint": [
                "browseId": "MPREb_test",
                "browseEndpointContextSupportedConfigs": [
                    "browseEndpointContextMusicConfig": [
                        "pageType": "MUSIC_PAGE_TYPE_ALBUM"
                    ]
                ]
            ]
        ]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "MPREb_test")
        XCTAssertEqual(resolved?.1, .album)
    }

    func testBrowseEndpointArtistPageType() {
        let endpoint: [String: Any] = [
            "browseEndpoint": [
                "browseId": "UC_test",
                "browseEndpointContextSupportedConfigs": [
                    "browseEndpointContextMusicConfig": [
                        "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                    ]
                ]
            ]
        ]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "UC_test")
        XCTAssertEqual(resolved?.1, .artist)
    }

    /// Playlist browseIds come back as `VL<plid>`. The parser strips
    /// the VL prefix so the resulting MediaItem.id is the playable id.
    func testBrowseEndpointPlaylistStripsVLPrefix() {
        let endpoint: [String: Any] = [
            "browseEndpoint": [
                "browseId": "VLPLtest123",
                "browseEndpointContextSupportedConfigs": [
                    "browseEndpointContextMusicConfig": [
                        "pageType": "MUSIC_PAGE_TYPE_PLAYLIST"
                    ]
                ]
            ]
        ]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "PLtest123")
        XCTAssertEqual(resolved?.1, .playlist)
    }

    /// Heuristic fallback when YT omits the pageType — id-prefix sniff.
    func testBrowseEndpointFallsBackToIdPrefix() {
        let endpoint: [String: Any] = [
            "browseEndpoint": ["browseId": "MPREb_xyz"]
        ]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "MPREb_xyz")
        XCTAssertEqual(resolved?.1, .album)
    }

    func testNilEndpointReturnsNil() {
        XCTAssertNil(InnerTubeClient.endpointToIdKind(nil))
        XCTAssertNil(InnerTubeClient.endpointToIdKind([:]))
    }

    // MARK: - parseListItem (search / library row)

    func testParseListItemSongRow() {
        let row: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [[
                                    "text": "Hello",
                                    "navigationEndpoint": [
                                        "watchEndpoint": ["videoId": "song123"]
                                    ]
                                ]]
                            ]
                        ]
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [
                                    [
                                        "text": "Adele",
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": "UCadele",
                                                "browseEndpointContextSupportedConfigs": [
                                                    "browseEndpointContextMusicConfig": [
                                                        "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ],
                                    ["text": " • "],
                                    [
                                        "text": "25",
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": "MPREb_25",
                                                "browseEndpointContextSupportedConfigs": [
                                                    "browseEndpointContextMusicConfig": [
                                                        "pageType": "MUSIC_PAGE_TYPE_ALBUM"
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseListItem(row)
        XCTAssertEqual(item?.id, "song123")
        XCTAssertEqual(item?.kind, .song)
        XCTAssertEqual(item?.title, "Hello")
        XCTAssertEqual(item?.artistId, "UCadele",
            "Artist run's browseId should be lifted into MediaItem.artistId")
        XCTAssertEqual(item?.albumId, "MPREb_25",
            "Album run's browseId should be lifted into MediaItem.albumId")
    }

    /// "Go to album / Go to artist" only show up on context menus when
    /// the parser surfaced these IDs, so this is the high-signal test
    /// that protects that whole feature.
    func testParseListItemMissingFlexColumnEndpointsFallsBackToMenu() {
        let row: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [[
                                    "text": "Some Song",
                                    "navigationEndpoint": [
                                        "watchEndpoint": ["videoId": "vidx"]
                                    ]
                                ]]
                            ]
                        ]
                    ]
                ],
                "menu": [
                    "menuRenderer": [
                        "items": [
                            [
                                "menuNavigationItemRenderer": [
                                    "navigationEndpoint": [
                                        "browseEndpoint": [
                                            "browseId": "UCfromMenu",
                                            "browseEndpointContextSupportedConfigs": [
                                                "browseEndpointContextMusicConfig": [
                                                    "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseListItem(row)
        XCTAssertEqual(item?.artistId, "UCfromMenu",
            "Menu fallback must pick up artist when flexColumns don't")
    }

    // MARK: - parseTwoRowItem (carousel tile)

    func testParseTwoRowItemTileWithSubtitleEndpoints() {
        let tile: [String: Any] = [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": "Levitating"]]],
                "subtitle": [
                    "runs": [
                        [
                            "text": "Dua Lipa",
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": "UCdua",
                                    "browseEndpointContextSupportedConfigs": [
                                        "browseEndpointContextMusicConfig": [
                                            "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                                        ]
                                    ]
                                ]
                            ]
                        ],
                        ["text": " • "],
                        [
                            "text": "Future Nostalgia",
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": "MPREb_fn",
                                    "browseEndpointContextSupportedConfigs": [
                                        "browseEndpointContextMusicConfig": [
                                            "pageType": "MUSIC_PAGE_TYPE_ALBUM"
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ],
                "navigationEndpoint": ["watchEndpoint": ["videoId": "lev123"]]
            ]
        ]
        let item = InnerTubeClient.parseTwoRowItem(tile)
        XCTAssertEqual(item?.id, "lev123")
        XCTAssertEqual(item?.kind, .song)
        XCTAssertEqual(item?.title, "Levitating")
        XCTAssertEqual(item?.subtitle, "Dua Lipa • Future Nostalgia")
        XCTAssertEqual(item?.artistId, "UCdua")
        XCTAssertEqual(item?.albumId, "MPREb_fn")
    }

    func testParseTwoRowItemReturnsNilOnMissingNavigation() {
        let tile: [String: Any] = [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": "Untitled"]]]
                // no navigationEndpoint at all
            ]
        ]
        XCTAssertNil(InnerTubeClient.parseTwoRowItem(tile),
            "Tiles without a navigation endpoint can't be played or opened, so the parser should drop them rather than returning a half-broken MediaItem")
    }

    // MARK: - parseHomeShelf

    func testParseHomeShelfCarouselWithTitle() {
        let shelf: [String: Any] = [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": "Listen Again"]]]
                    ]
                ],
                "contents": [
                    [
                        "musicTwoRowItemRenderer": [
                            "title": ["runs": [["text": "Track A"]]],
                            "subtitle": ["runs": [["text": "Artist A"]]],
                            "navigationEndpoint": ["watchEndpoint": ["videoId": "a1"]]
                        ]
                    ],
                    [
                        "musicTwoRowItemRenderer": [
                            "title": ["runs": [["text": "Track B"]]],
                            "subtitle": ["runs": [["text": "Artist B"]]],
                            "navigationEndpoint": ["watchEndpoint": ["videoId": "b1"]]
                        ]
                    ]
                ]
            ]
        ]
        let section = InnerTubeClient.parseHomeShelf(shelf)
        XCTAssertEqual(section?.title, "Listen Again")
        XCTAssertEqual(section?.items.count, 2)
        XCTAssertEqual(section?.items.first?.id, "a1")
        XCTAssertEqual(section?.items.last?.id, "b1")
    }

    func testParseHomeShelfDropsEmpty() {
        let shelf: [String: Any] = [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": "Empty Rail"]]]
                    ]
                ],
                "contents": []
            ]
        ]
        XCTAssertNil(InnerTubeClient.parseHomeShelf(shelf),
            "Shelves with no parsable items must be dropped — otherwise empty rails leak into Home")
    }

    // MARK: - parseRelatedSections

    /// Mimic the /next Related-tab browse response shape: a
    /// `singleColumnBrowseResultsRenderer` with a single tab whose
    /// `sectionListRenderer.contents` hold one or more
    /// `musicCarouselShelfRenderer` shelves. A real response carries
    /// an "Other versions" shelf (live / acoustic / cover variants)
    /// + "Recommended tracks"; we verify both are surfaced as
    /// titled HomeSections with their items intact.
    func testParseRelatedSectionsSurfacesTitledShelves() {
        let body: [String: Any] = [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "musicCarouselShelfRenderer": [
                                                "header": [
                                                    "musicCarouselShelfBasicHeaderRenderer": [
                                                        "title": ["runs": [["text": "Other versions"]]]
                                                    ]
                                                ],
                                                "contents": [[
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Sample Song (Live)"]]],
                                                        "subtitle": ["runs": [["text": "Artist"]]],
                                                        "navigationEndpoint": ["watchEndpoint": ["videoId": "live1"]]
                                                    ]
                                                ], [
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Sample Song (Acoustic)"]]],
                                                        "subtitle": ["runs": [["text": "Artist"]]],
                                                        "navigationEndpoint": ["watchEndpoint": ["videoId": "acou1"]]
                                                    ]
                                                ]]
                                            ]
                                        ],
                                        [
                                            "musicCarouselShelfRenderer": [
                                                "header": [
                                                    "musicCarouselShelfBasicHeaderRenderer": [
                                                        "title": ["runs": [["text": "Recommended tracks"]]]
                                                    ]
                                                ],
                                                "contents": [[
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Other Song"]]],
                                                        "subtitle": ["runs": [["text": "Other Artist"]]],
                                                        "navigationEndpoint": ["watchEndpoint": ["videoId": "rec1"]]
                                                    ]
                                                ]]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let sections = InnerTubeClient.parseRelatedSections(body)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.first?.title, "Other versions")
        XCTAssertEqual(sections.first?.items.count, 2)
        XCTAssertEqual(sections.first?.items.map(\.id), ["live1", "acou1"])
        XCTAssertEqual(sections.last?.title, "Recommended tracks")
        XCTAssertEqual(sections.last?.items.first?.id, "rec1")
    }

    /// Empty / unrecognized response — parser must not crash and must
    /// return an empty array so callers can fall back to flat related.
    func testParseRelatedSectionsEmptyOnUnknownShape() {
        XCTAssertTrue(InnerTubeClient.parseRelatedSections([:]).isEmpty)
        XCTAssertTrue(InnerTubeClient.parseRelatedSections(["contents": "garbage"]).isEmpty)
    }

    // MARK: - parseHomeChips

    /// Standard FEmusic_home response shape — chip cloud lives under
    /// sectionListRenderer.header.chipCloudRenderer.chips. Each chip
    /// must surface its label plus the browseEndpoint.params blob the
    /// follow-up filtered-home browse needs.
    func testParseHomeChipsStandardShape() {
        let body: [String: Any] = [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "header": [
                                        "chipCloudRenderer": [
                                            "chips": [
                                                [
                                                    "chipCloudChipRenderer": [
                                                        "text": ["runs": [["text": "Workout"]]],
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": [
                                                                "browseId": "FEmusic_home",
                                                                "params": "WORKOUT_PARAMS"
                                                            ]
                                                        ]
                                                    ]
                                                ],
                                                [
                                                    "chipCloudChipRenderer": [
                                                        "text": ["runs": [["text": "Focus"]]],
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": [
                                                                "browseId": "FEmusic_home",
                                                                "params": "FOCUS_PARAMS"
                                                            ]
                                                        ]
                                                    ]
                                                ],
                                                // Empty label — must be dropped.
                                                [
                                                    "chipCloudChipRenderer": [
                                                        "text": ["runs": [["text": ""]]],
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["params": "X"]
                                                        ]
                                                    ]
                                                ],
                                                // Missing params — must be dropped.
                                                [
                                                    "chipCloudChipRenderer": [
                                                        "text": ["runs": [["text": "NoParams"]]],
                                                        "navigationEndpoint": [
                                                            "browseEndpoint": ["browseId": "FEmusic_home"]
                                                        ]
                                                    ]
                                                ],
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let chips = InnerTubeClient.parseHomeChips(body)
        XCTAssertEqual(chips.count, 2, "Empty-label and missing-params chips must be dropped")
        XCTAssertEqual(chips.map(\.label), ["Workout", "Focus"])
        XCTAssertEqual(chips.map(\.params), ["WORKOUT_PARAMS", "FOCUS_PARAMS"])
    }

    /// Defense against renderer drift — when YT returns an unknown
    /// shape, parseHomeChips must return empty so HomeView simply
    /// renders without the chip row rather than crashing.
    func testParseHomeChipsEmptyOnUnknownShape() {
        XCTAssertTrue(InnerTubeClient.parseHomeChips([:]).isEmpty)
        XCTAssertTrue(InnerTubeClient.parseHomeChips(["contents": "garbage"]).isEmpty)
    }

    // MARK: - MediaItem Codable round-trip

    /// Played-history persistence relies on this. If MediaItem ever
    /// gains a non-Codable field, this catches it before users lose
    /// their history on next launch.
    func testMediaItemCodableRoundTrip() throws {
        let item = MediaItem(
            id: "vid",
            kind: .song,
            title: "Song",
            subtitle: "Artist",
            thumbnailURL: URL(string: "https://example.com/a.jpg"),
            albumId: "MPREb",
            artistId: "UC",
            durationSeconds: 222,
            year: 2024
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertEqual(item, decoded)
    }

    // MARK: - parseDurationString

    func testParseDurationMMSS() {
        XCTAssertEqual(InnerTubeClient.parseDurationString("3:42"), 222)
        XCTAssertEqual(InnerTubeClient.parseDurationString("0:30"), 30)
        XCTAssertEqual(InnerTubeClient.parseDurationString("10:00"), 600)
    }

    func testParseDurationHMMSS() {
        XCTAssertEqual(InnerTubeClient.parseDurationString("1:23:45"), 5025)
        XCTAssertEqual(InnerTubeClient.parseDurationString("2:00:00"), 7200)
    }

    func testParseDurationRejectsGarbage() {
        XCTAssertNil(InnerTubeClient.parseDurationString(""))
        XCTAssertNil(InnerTubeClient.parseDurationString("LIVE"))
        XCTAssertNil(InnerTubeClient.parseDurationString("3:42:00:00"))
        XCTAssertNil(InnerTubeClient.parseDurationString("0:00"),
            "Zero-length not a real duration; rejecting it avoids fake matches on placeholders")
        XCTAssertNil(InnerTubeClient.parseDurationString(":42"))
        XCTAssertNil(InnerTubeClient.parseDurationString("3:"))
    }

    func testParseDurationTrimsWhitespace() {
        XCTAssertEqual(InnerTubeClient.parseDurationString("  3:42  "), 222)
    }

    // MARK: - duration + year via parseListItem

    /// List-row songs (search "Songs" shelf, library liked-songs)
    /// carry duration in fixedColumns and year in flexColumns. This
    /// fixture mimics a real row with both populated.
    func testParseListItemExtractsDurationAndYear() {
        let row: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [[
                                    "text": "Sample Song",
                                    "navigationEndpoint": [
                                        "watchEndpoint": ["videoId": "v1"]
                                    ]
                                ]]
                            ]
                        ]
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [
                                    ["text": "Some Artist"],
                                    ["text": " • "],
                                    ["text": "2021"]
                                ]
                            ]
                        ]
                    ]
                ],
                "fixedColumns": [
                    [
                        "musicResponsiveListItemFixedColumnRenderer": [
                            "text": ["runs": [["text": "3:42"]]]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseListItem(row)
        XCTAssertEqual(item?.durationSeconds, 222)
        XCTAssertEqual(item?.year, 2021)
    }

    /// Year run with a navigationEndpoint must NOT be parsed as a
    /// year. Real-world case: artist named "1975" (the band) — their
    /// artist run has a browseEndpoint, so we have to ignore it.
    func testYearExtractorIgnoresLinkedNumericRuns() {
        let row: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [[
                                    "text": "Song",
                                    "navigationEndpoint": [
                                        "watchEndpoint": ["videoId": "v2"]
                                    ]
                                ]]
                            ]
                        ]
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [
                                    [
                                        "text": "1975",
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": "UC1975",
                                                "browseEndpointContextSupportedConfigs": [
                                                    "browseEndpointContextMusicConfig": [
                                                        "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseListItem(row)
        XCTAssertNil(item?.year, "Linked numeric runs are artist refs, not years")
    }

    // MARK: - year via parseTwoRowItem

    func testParseTwoRowItemExtractsYearFromSubtitle() {
        let tile: [String: Any] = [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": "Some Album"]]],
                "subtitle": [
                    "runs": [
                        ["text": "Artist"],
                        ["text": " • "],
                        ["text": "2019"]
                    ]
                ],
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": "MPREb_sa",
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_ALBUM"
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseTwoRowItem(tile)
        XCTAssertEqual(item?.year, 2019)
    }

    // MARK: - search continuation tokens (B11)

    /// A kind-scoped /search response carries its continuation token on
    /// the `musicShelfRenderer` that holds the row list. We synthesize
    /// the same shape `searchPaged` walks (a flat shelves array) and
    /// confirm the token surfaces.
    func testFindSearchContinuationTokenOnMusicShelf() {
        let shelves: [[String: Any]] = [[
            "musicShelfRenderer": [
                "contents": [],
                "continuations": [[
                    "nextContinuationData": ["continuation": "TOKEN_A"]
                ]]
            ]
        ]]
        XCTAssertEqual(InnerTubeClient.findSearchContinuationToken(in: shelves), "TOKEN_A")
    }

    /// Reload-style continuations (older shape) should still resolve.
    func testFindSearchContinuationTokenReloadShape() {
        let shelves: [[String: Any]] = [[
            "musicShelfRenderer": [
                "contents": [],
                "continuations": [[
                    "reloadContinuationData": ["continuation": "TOKEN_B"]
                ]]
            ]
        ]]
        XCTAssertEqual(InnerTubeClient.findSearchContinuationToken(in: shelves), "TOKEN_B")
    }

    /// The `.all` filter response is a heterogeneous stack of shelves
    /// without any top-level continuation token — make sure we return
    /// nil rather than hallucinating one.
    func testFindSearchContinuationTokenMissingReturnsNil() {
        let shelves: [[String: Any]] = [[
            "musicShelfRenderer": [
                "contents": []
            ]
        ]]
        XCTAssertNil(InnerTubeClient.findSearchContinuationToken(in: shelves))
    }

    /// An empty continuation string is treated as no-more (some
    /// responses carry an empty placeholder where the real token
    /// would land).
    func testFindSearchContinuationTokenEmptyStringTreatedAsNil() {
        let shelves: [[String: Any]] = [[
            "musicShelfRenderer": [
                "contents": [],
                "continuations": [[
                    "nextContinuationData": ["continuation": ""]
                ]]
            ]
        ]]
        XCTAssertNil(InnerTubeClient.findSearchContinuationToken(in: shelves))
    }

    /// `parseSearchShelves` is shared between the initial /search and
    /// the continuation parse. Confirm a continuation-shaped row list
    /// (synthesized by wrapping `musicShelfContinuation` as a fake
    /// `musicShelfRenderer`) flattens to the same MediaItem shape the
    /// initial parse produces.
    func testParseSearchShelvesFlattensListRows() {
        let row: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [[
                    "musicResponsiveListItemFlexColumnRenderer": [
                        "text": [
                            "runs": [[
                                "text": "Continuation Song",
                                "navigationEndpoint": [
                                    "watchEndpoint": ["videoId": "vCont"]
                                ]
                            ]]
                        ]
                    ]
                ]]
            ]
        ]
        let shelves: [[String: Any]] = [[
            "musicShelfRenderer": [
                "contents": [row]
            ]
        ]]
        let items = InnerTubeClient.parseSearchShelves(shelves)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "vCont")
        XCTAssertEqual(items.first?.title, "Continuation Song")
    }

    // MARK: - D3 followed-artist feed: releasesFromArtistDetail

    /// Helper: build a `DetailPage` carrying the given relatedSections,
    /// stubbing out the header/tracklist fields that
    /// `releasesFromArtistDetail` doesn't read.
    private func makeArtistDetailPage(sections: [HomeSection]) -> InnerTubeClient.DetailPage {
        InnerTubeClient.DetailPage(
            title: "Test Artist",
            subtitle: "",
            subtitleRuns: [],
            artworkURL: nil,
            playablePlaylistId: nil,
            tracks: [],
            relatedSections: sections
        )
    }

    /// Album / Single / EP shelves are picked up; "Videos" and
    /// "Fans might also like" are excluded. Song-shaped tiles inside
    /// a Singles shelf are dropped so only album-shaped items (which
    /// carry release-year metadata + a navigable browseId) make it
    /// into the feed.
    func testReleasesFromArtistDetailPicksAlbumsSinglesEPs() {
        let album = MediaItem(id: "alb1", kind: .album, title: "Album One",
                              subtitle: "Artist · 2026", thumbnailURL: nil, year: 2026)
        let single = MediaItem(id: "sng1", kind: .album, title: "Single One",
                               subtitle: "Artist · 2025", thumbnailURL: nil, year: 2025)
        let ep = MediaItem(id: "epA", kind: .album, title: "EP A",
                           subtitle: "Artist · 2024", thumbnailURL: nil, year: 2024)
        let songTile = MediaItem(id: "songInSingleRail", kind: .song,
                                 title: "Track-only tile", subtitle: "Artist",
                                 thumbnailURL: nil)
        // Videos rails carry WATCH tiles — kind .song in the parser —
        // which is exactly why the structural (kind == .album) filter
        // excludes them in every locale.
        let video = MediaItem(id: "vid1", kind: .song, title: "Music Video",
                              subtitle: "Artist", thumbnailURL: nil)
        let related = MediaItem(id: "rel1", kind: .artist, title: "Other Artist",
                                subtitle: "", thumbnailURL: nil)

        let sections: [HomeSection] = [
            HomeSection(id: "Albums", title: "Albums", items: [album]),
            // Mixed-kind Singles rail: album-shaped single keeps, song-shaped tile drops.
            HomeSection(id: "Singles", title: "Singles", items: [single, songTile]),
            HomeSection(id: "EPs", title: "EPs", items: [ep]),
            HomeSection(id: "Videos", title: "Videos", items: [video]),
            HomeSection(id: "Fans", title: "Fans might also like", items: [related]),
        ]
        let page = makeArtistDetailPage(sections: sections)
        let releases = InnerTubeClient.releasesFromArtistDetail(page)

        let ids = Set(releases.map(\.id))
        XCTAssertTrue(ids.contains("alb1"))
        XCTAssertTrue(ids.contains("sng1"))
        XCTAssertTrue(ids.contains("epA"))
        XCTAssertFalse(ids.contains("songInSingleRail"),
                       "song-shaped tiles inside Singles rail must be filtered out")
        XCTAssertFalse(ids.contains("vid1"),
                       "watch tiles (.song) are never releases, whatever their shelf")
        XCTAssertFalse(ids.contains("rel1"),
                       "'Fans might also like' must not bleed into the followed feed")
    }

    /// Selection is structural (kind == .album), so localized shelf
    /// titles keep their release tiles — the old English keyword
    /// filter silently dropped whole rails outside `en`.
    func testReleasesFromArtistDetailIsLocaleIndependent() {
        let a = MediaItem(id: "a", kind: .album, title: "Disco Uno",
                          subtitle: "", thumbnailURL: nil)
        let b = MediaItem(id: "b", kind: .album, title: "Album Eins",
                          subtitle: "", thumbnailURL: nil)
        let watch = MediaItem(id: "w", kind: .song, title: "Video en vivo",
                              subtitle: "", thumbnailURL: nil)
        let page = makeArtistDetailPage(sections: [
            HomeSection(id: "1", title: "Álbumes", items: [a]),
            HomeSection(id: "2", title: "アルバム", items: [b]),
            HomeSection(id: "3", title: "Vídeos", items: [watch]),
        ])
        let releases = InnerTubeClient.releasesFromArtistDetail(page)
        let ids = Set(releases.map(\.id))
        XCTAssertTrue(ids.contains("a"), "Spanish Albums rail keeps its album tiles")
        XCTAssertTrue(ids.contains("b"), "Japanese Albums rail keeps its album tiles")
        XCTAssertFalse(ids.contains("w"),
                       "watch tiles are not releases, whatever the shelf is called")
    }

    /// Empty relatedSections → empty releases, no crash.
    func testReleasesFromArtistDetailEmptySections() {
        let page = makeArtistDetailPage(sections: [])
        XCTAssertTrue(InnerTubeClient.releasesFromArtistDetail(page).isEmpty)
    }
}
