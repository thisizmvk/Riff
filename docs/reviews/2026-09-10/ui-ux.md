# Riff UI/UX audit — Explore, Search, Library, Detail, Player surfaces

Reviewer: nakula (Senior Frontend Engineer). Branch `queue-and-ux-enhancements`. Read-only audit; no repo changes.

**Reference bar ("tuned")** — `Sources/UI/Home/HomeView.swift` + `Components/ThumbnailButton.swift` + `Components/ArtistLinkLine.swift` + `Components/Theme.swift`:
180pt tiles, 12pt radius, 28pt/bold section titles, 24pt gutters, 32pt section spacing, hover-lift + directional shadow, red 3pt focus ring, hover chevrons, ←/→ tile focus, cache-first render, pulsing skeleton, `ErrorBanner`, subtitle at 0.85 white for AA, reduce-motion honoured, VoiceOver label composed per tile, `.help` tooltip for truncated text.

**Constraints honoured by every recommendation below**: WKWebView stays hidden; zero new dependencies; nothing touches `QueuePolicy`, `PlayerBridge` navigate/`play(item:)` counts, or the behavior contract in `docs/QUEUE-DESIGN.md`. All queue interactions proposed reuse existing bridge API (`skipTo`, `playNext`, `addToQueueEnd`, `removeFromQueue`, `moveInQueue`, `reorderQueue`, `clearUpNext`).

---

## A. Per-surface audit

### A.0 Cross-cutting (affects every surface)

| Finding | Evidence | Note |
|---|---|---|
| Design tokens exist but are not adopted | `Theme.swift:22-25` defines `surface`, `surfaceHover`, `divider`; `grep` shows **0** uses of `Theme.surface`/`surfaceHover` anywhere; `Theme.divider` only via `Divider().background(...)`. Raw `Color.white.opacity(0.04…0.18)` appears 15× in NowPlayingView alone, 4× SearchView, 4× SearchResultRow, 3× Library, 3× Detail. | Every surface hand-rolls the same fills. |
| Corner-radius scale has 11 distinct values | grep: 8 (12×), 6 (12×), 4 (9×), 12 (9×), 10 (8×), 14 (3×), plus 1.5, 3, 5, 16, 18. | Home uses 12 (tile) / 8 (row) / 6 (thumb). Need `Theme.Radius`. |
| Secondary-text opacity ranges 0.45–0.9 | ThumbnailButton:275-279 raised subtitle to 0.85 for WCAG AA; but TrackRow (`DetailView.swift:701,715`) uses **0.55**, EmptyState subtitle 0.6 (`EmptyState.swift:46`), TopResultCard 0.7 (`SearchResultRow.swift:278`), SearchResultRow 0.75 (`:137`), history rows 0.75 × 0.6 fade (`NowPlayingView.swift:1910`). | 0.55 white on black at 12pt ≈ 3.2:1 — fails AA. |
| `Theme.Motion` is used in 2 places; 12 hard-coded animations | `RiffApp.swift:365`, `NowPlayingView.swift:1960` use tokens. Hard-coded: NowPlayingView ×4 (`:106,141,320,1715`), HomeView ×3, ThumbnailButton, DetailView `:742`, Explore, FloatingMiniPlayer `:103`, CommandPalette. | The motion discipline the token comment describes isn't enforced. |
| Reduce-motion honoured in 3 files only | `accessibilityReduceMotion` in ThumbnailButton, NowPlayingView, RiffApp. Skeleton pulses run `repeatForever` unconditionally (`HomeView.swift:322`, `ExploreView.swift:111`); TrackRow hover cross-fade (`DetailView.swift:742`) and Floating hover fade (`FloatingMiniPlayer.swift:103`) ignore it. | |
| `Divider().background(color)` does not recolor a Divider | 19 sites (`NowPlayingView` ×4, `DetailView:94,412`, `CommandPalette:44,74`, Settings ×10, EditPlaylistSheet). The system separator still draws its own colour; `.background` paints a 1pt rect *behind* it. | Replace with a `Theme.Hairline` view (`Rectangle().fill(Theme.divider).frame(height: 1)`). |
| Five chip implementations, two sort pills, three skeletons, three `nowPlayingMenuItems`, three speaker-icon switches | Chips: `MoodChipPill` (Home:251), `FilterChip` (Search:785), `RefinementChip` (Search:807), recent-search chip (Search:734), suggestion chip (Search:339), `miniChip` ×2 (Floating:178, MenuBar:296), Tune chip (NowPlaying:2355). Sort pill: `LibraryView:173-200` ≈ `TrackSortMenu:44-72`. Skeleton: `HomeSkeleton`, `ExploreSkeleton` (missing subtitle bar vs Home), Library inline (`:474-484`). `nowPlayingMenuItems` in Mini:141, Floating:145, NowPlaying:683. Speaker icon ternary in Mini:88, MenuBar:107, NowPlaying:505. | Consolidate into Components. |
| Active-chip colour semantics differ per surface | Home active = `Theme.red` fill + black text (`HomeView:261-268`); Search kind filter active = **white** fill (`SearchView:795`); refinement active = red 0.85 (`:700`); Tune chip active = red + white text (`NowPlaying:2362-2363`). | The user learns "red = selected" on Home and then sees white on Search. |
| Hover feedback missing on Search chips and queue rows | `SearchView.swift` has **0** `onHover`; `queueRow` background is a constant `0.04` (`NowPlayingView:2081`). Home chips (`:280`) and every other row hover. | |
| Player open/close unmounts the whole tab tree | `RiffApp.swift:352-363` swaps `NowPlayingView` ⇄ `MainTabs` with `if/else`. Every close re-creates Home/Explore/Search/Library: Explore re-fetches and shows its skeleton (`ExploreView:49` sets `loading = true` every `load()`), Library refetches (`.task(id: section)`), Search refocuses the field, scroll positions reset. | Comment at `:349-351` cites an overlay leak — that was almost certainly the ZStack backdrop-inflation bug now fixed by `.background{}` (memory note). |
| Dark/light: app is forced dark, MenuBarExtra is not | `RiffApp.swift:62` `.preferredColorScheme(.dark)` on the WindowGroup only; `MenuBarExtra` (`:136`) follows system. `MenuBarMiniPlayer` mixes adaptive `.primary/.secondary` (9×) with non-adaptive `Color.white.opacity(0.12)` progress track (`:42`) and `0.08` chip fill (`:305`) → invisible in Light menu bar. | |
| macOS conventions | No `.toolbar` anywhere (grep 0); `.hiddenTitleBar`. Nav back relies on the OS back chevron or "tap the active tab again" (`RiffApp:458-467`). No `⌘[` back, no `⌘R` refresh. Drag & drop exists only for queue reorder (`QueueDragReorderModifier`); tiles/rows are not draggable *into* the queue. Context menus: excellent coverage via `TrackContextMenu`. | Verify a visible back affordance exists on Detail pages; if the OS chevron is absent under hidden title bar, add one in-content. |
| `NSCursor.push()/pop()` in three progress strips | `MiniPlayerView:40`, `FloatingMiniPlayer:126`, `MenuBarMiniPlayer:57`. Push/pop is unbalanced if hover-exit is missed (window deactivation, popover dismiss) → cursor stuck as hand. | One `PointingHandOnHover` modifier using `NSCursor.pointingHand.set()` / `.arrow.set()`. |

### A.1 Explore — `Sources/UI/Explore/ExploreView.swift`

**Good**
- Reuses `HomeSection` + `HomeSectionRow` (`:32-36`) so tiles, hover chevrons, ←/→ focus, now-playing badge all match Home exactly.
- Parallel `async let` for explore + moods (`:51-54`), blocked-artist filter, `ErrorBanner` with retry, skeleton on cold load.

**Inconsistent / missing**
- **No cache-first render.** Home paints `HomeFeedCache` instantly (`HomeView:157-163`); Explore sets `loading = true` on every `load()` (`:49`) → skeleton on every tab visit and after every player close.
- **Page title collides with section titles.** `ExploreHeader` is 28pt bold (`:76`) — identical to `HomeSectionRow` section titles (`HomeView:361`). No hierarchy; Home has no page header at all, so Explore is the odd tab. Either drop the header (match Home/Search/Library) or use 32pt like `DetailView:165` with the tagline.
- **Moods & Genres rendered as artwork tiles.** `moods` go through `HomeSectionRow` (`:34-36`) → 180×180 `ThumbnailButton`s. YT Music mood/genre entries are colour-bar chips with no artwork; they will fall to the SF-symbol placeholder (`ThumbnailButton:139-151`). Should render as a chip grid / bento (`MoodChipPill` style or a 2-line colour card).
- **Blank page when both lists are empty and no error** (`:28-37`): anonymous session with everything filtered → nothing, not even `EmptyState`.
- `ExploreSkeleton` (`:86-116`) is a private copy of `HomeSkeleton` minus the subtitle bar (`:101-103` vs `HomeView:309-314`); pulse ignores reduce-motion (`:111`).
- 0 `accessibilityLabel` / `.help` — acceptable only because all controls are inside `HomeSectionRow`.

### A.2 Search — `Sources/UI/Search/SearchView.swift`, `SearchResultRow.swift`

**Good**
- Debounced search + 150ms suggestions (`:196-212`), recent-search chips, URL paste → deep link (`:180-186`), `⌘F` focus token.
- Keyboard traversal ↑/↓/↵ (`:410-424`) with a red focus tint on rows (`SearchResultRow:149-158`).
- Distinct empty states (initial / no results / filtered-to-zero) via `EmptyState` (`:345-380`).
- Top-result hero card + kind grouping, infinite scroll with retry footer (`:502-540`), continuation de-dupe.
- Artist thumbnails are circles (`SearchResultRow:163-168`) — matches `ThumbnailButton`.

**Inconsistent / missing**
- **Stock `.roundedBorder` TextField** (`:176`) — the only AppKit-styled input in the browse UI. Library's filter field is a custom capsule (`LibraryView:152-163`); CommandPalette a plain field in a dark container. The white/grey system field is the loudest non-native-feeling element on the Search tab. No clear (`xmark.circle.fill`) button either.
- **Selected-chip colour differs from Home** (`FilterChip:795` white vs `MoodChipPill` red). **No hover state on any Search chip** (0 `onHover` in file).
- **Keyboard focus doesn't scroll.** `moveFocus` (`:433-446`) sets `focusedResultId` but there's no `ScrollViewReader.scrollTo`; Home's `moveFocus` scrolls (`HomeView:426-428`). Arrow past the fold → invisible focus.
- **`⌘↵` "adds to queue" is documented (`:15-17`) but not implemented** — only `.return` is handled (`:418`). Esc-to-return-to-field is described in a comment (`:437-438`) but not wired.
- **Rows lack the hover quick-action cluster** that tiles have (`ThumbnailButton:227-252` Play-next / Add-to-queue). Search rows are context-menu-only.
- **Artist not clickable in rows.** `SearchResultRow:135-138` and `TopResultCard:276-279` are plain `Text`; queue rows and Now Playing use `ArtistLinkLine`. Inconsistent affordance for the same subtitle string.
- Subtitle opacity 0.75/0.7 vs the 0.85 floor set in `ThumbnailButton:275-279`.
- **Layout jump**: refinement + sort rows appear only when `!results.isEmpty` (`:270`, `:314`); as results arrive/clear, the list shifts by ~60pt. Reserve the space or animate with `Theme.Motion.subtle`.
- Loading state is `ProgressView` + "Searching…" (`:336-344`) — Home/Explore use skeletons; a 5-row skeleton list would keep the tab consistent and avoid the centred spinner.
- 0 `accessibilityLabel`, 0 `.help` in `SearchView.swift`. Filter chips carry no `.isSelected` trait (TopTabBar does this right, `RiffApp:481`).
- `TopResultCard` for an artist shows a "Play" pill that starts artist radio (`:334-341`); copy could read "Start radio" (matches the context-menu label).

### A.3 Library — `Sources/UI/Library/LibraryView.swift`, `LibrarySorting.swift`

**Good**
- Per-section empty states with icon/title/subtitle/CTA (`:300-344`); filter-to-zero state with "Clear filter" CTA; session-expiry heuristic (`:427-430`).
- Live filter capsule field (`:152-163`) — the input style Search should adopt.
- Pin badge (`:258-276`), pinned partition preserving sort, `ThumbnailButton(showPinAction:)`.
- Best-effort rails (Mixed for you, New from followed artists) fail silently rather than banner.

**Inconsistent / missing**
- **Stock segmented `Picker`** (`:137-146`) — the only system segmented control in the app; every other selector is a custom chip row or underline tab. It renders as a bright AppKit control on black.
- **No loading state.** `load()` never sets a loading flag. On section switch, stale `items` from the previous section render under the new label until the fetch lands, or on cold load the "No liked songs yet" `EmptyState` **flashes** before data arrives (`:234`). Home/Explore have skeletons.
- **Adaptive grid with fixed-width tiles.** `GridItem(.adaptive(minimum: 180))` (`:255`) stretches columns but `ThumbnailButton` is fixed 180 (`ThumbnailButton:283`) → tiles left-align in wider cells; right gutter varies with window width. Use `.adaptive(minimum: 180, maximum: 180)` or centre.
- **No arrow-key navigation in the grid.** Home rails have ←/→; the Library grid (the most keyboard-scannable surface) has none, though `ThumbnailButton.externalFocus` already supports it.
- **Anonymous state bypasses `EmptyState`** (`:346-367`): 56pt `.secondary` icon, 22pt title, `.tint(.red)` (system red, not `Theme.red`), `borderedProminent`. Every other empty state uses the 88pt puck + red capsule CTA.
- **Liked / History as artwork tiles.** A list of individual songs rendered as 180×180 tiles hides duration and index and reads as albums. YT Music iOS Liked Songs and History are track lists. `TrackRow` (Detail) is the right component for `.liked` and `.history`; keep the grid for Playlists/Albums/Artists/Podcasts.
- `followedReleasesRail` (`:462-496`) is a bare horizontal `ScrollView` + `ThumbnailButton` — no hover chevrons, no ←/→ (Home has both via `HomeSectionRow`); title is 22pt (`:466`) vs 28pt for the Mixed-for-you rails directly above it (`HomeSectionRow`). Build a `HomeSection` and reuse the row.
- Mixed-for-you `LazyVStack(spacing: 24)` (`:220`) vs Home `32`.
- Sort pill (`:173-200`) duplicates `TrackSortMenu`'s label; 0 `accessibilityLabel` on the sort menu/pin badge.

### A.4 Detail (album / playlist / artist / podcast) — `Sources/UI/Detail/DetailView.swift`

**Good**
- Header hierarchy: 11pt tracked eyebrow → 32pt bold title → linkable subtitle runs → metadata line (`:158-180`). Metadata "9 songs • 32 min • 2024" with pluralisation.
- `TrackRow`: number → play arrow on hover → equalizer when current (`:823-848`), red current-row tint (`:728-736`), hover-revealed like + ⋯ (`:760-819`), remove-from-playlist for owned playlists, duration column, artwork/artist backfill (`:572-590`).
- Follow / Don't-recommend inline on artists; Edit menu on owned playlists; related carousels reuse `HomeSectionRow`.

**Inconsistent / missing**
- **32pt gutters vs 24pt everywhere else** (`:99,114,243,415,720`). Content jumps 8pt inward when a detail page is pushed from Home/Search/Library.
- **Loading = bare `ProgressView`** (`:126`). No header/row skeleton; Home/Explore set the expectation.
- **No artwork-derived backdrop.** `DominantColor` + blurred-art wash exist for Now Playing (`NowPlayingView:107-142`); the detail header on black feels flat by comparison (YTM desktop/iOS both tint the header). Must be added via `.background { }` — never as a ZStack sibling (see memory: fullscreen inflation).
- **Artist header artwork is a rounded square** (`:155` unconditional `RoundedRectangle(14)`); tiles/rows render artists as circles (`ThumbnailButton:48`, `SearchResultRow:164`). Break in the person-vs-container language.
- **Three CTA styles across the app.** Detail uses `.borderedProminent.tint(Theme.red)` + `.bordered` with extra `Label` padding (`:183-202`) → double-padded stock AppKit buttons; TopResultCard uses a custom white capsule (`SearchResultRow:286-301`); `EmptyState` uses a custom red capsule (`EmptyState:51-69`). Need `PrimaryCapsuleButtonStyle` / `SecondaryCapsuleButtonStyle` in Theme.
- Artist pages can stack Play + Shuffle + Follow + Don't Recommend in one `HStack(spacing: 10)` (`:182-239`) — no wrapping; tight at 980pt min width with a 220pt cover. Consider moving Don't Recommend into the ⋯ menu (it's already in `TrackContextMenu`).
- Edit `⋯` Menu (`:209-223`) has no background/border — the ellipsis floats next to two filled buttons.
- `Text("No tracks")` (`:96`) instead of `EmptyState`.
- **`TrackRow` subtitle & duration at 0.55 opacity** (`:701,715`) — fails AA; the tile component documents 0.85 as the floor.
- `TrackRow` subtitle is plain `Text` (`:698-702`), not `ArtistLinkLine` — artists on playlist rows aren't clickable although they are in queue rows.
- **No keyboard traversal or focus styling on `TrackRow`** — Search rows have ↑↓↵ + red focus tint; tracklist rows have neither.
- `TrackRow` heart starts hollow even on the Liked Songs playlist (`:666`, `likedOptimistic = false`) — every row on `LM` is liked; pass `initiallyLiked` when the page id is the liked-songs playlist.
- `.animation(.easeOut(0.15), value: hovering)` (`:742`) ignores reduce-motion; `ThumbnailButton:288` handles it.
- No visible in-page back affordance (no `.toolbar`, hidden title bar). Verify the OS back chevron renders; otherwise add `chevron.left` + `⌘[`.

### A.5 Player surfaces

#### `MiniPlayerView.swift`
**Good** — 6pt seek strip with pointing-hand and a11y label (`:31-45`), 52pt art with shadow, `.contextMenu { TrackContextMenu }`, explicit "Open Now Playing" a11y action (`:120-126`).
**Gaps**
- Placeholder `Color.gray.opacity(0.2)` (`:51`) is the only `Color.gray` in the app; subtitle uses `.secondary` (`:66`) instead of the white-opacity token; no `music.note` glyph like queue rows / MenuBar.
- `controlButton` (`:157-168`) has `.help` but **no `accessibilityLabel`** — VoiceOver reads "backward.fill". `NowPlayingView:818` mirrors help→label; Mini doesn't.
- No like, no queue toggle. YTM desktop's bar has ♥ and a queue button; both are one-liners here (`toggleLike()`, `isFullPlayerOpen = true` + `bottomTab = .upNext`).
- Subtitle is plain `Text`; `ArtistLinkLine` works inside a tappable strip (Button wins the hit test — see `NowPlayingView:2030-2033`).
- Seek strip commits only `onEnded` (`:33-37`); no live scrub, no hover time tooltip. `ScrubberSlider` (`NowPlayingView:2209`) already does live drag + keyboard nudge + VoiceOver adjustable — reuse a 4pt variant.

#### `FloatingMiniPlayer.swift`
**Good** — hover-reveal scrim + transport (`:66-104`), gradient title block always readable, floating level + joins all spaces (`:200-216`), context menu, chips.
**Gaps**
- Hover fade (`:103`) ignores reduce-motion.
- Transport is unreachable without a mouse: `allowsHitTesting(isHovering)` + `opacity(0)` (`:102-104`) → keyboard/VoiceOver users get nothing. Add `.accessibilityHidden(!isHovering)` at minimum, or keep the transport always accessible.
- Chip font **9pt** (`:184`) — below the 10pt readability floor; MenuBar uses 11.
- No close affordance (title hidden, `titleVisibility = .hidden`); ⌘W only. A hover-reveal `xmark` top-left matches the hover-transport pattern.
- Artwork placeholder is a bare `Color.black.opacity(0.92)` (`:34`) — no glyph, unlike queue rows / MenuBar.
- At the 280×140 minimum the chip strip + transport + 42pt spacer + title block exceed 140pt; verify overlap.

#### `MenuBarMiniPlayer.swift`
**Good** — the most complete compact surface: progress + timestamps (`:38-69`), transport disabled without a track, mode toggles, volume, chips, sleep/crossfade/rate submenus, like, save queue, open mini, quit; `accessibilityValue` on volume.
**Gaps**
- **Light-mode breakage**: adaptive `.primary/.secondary` mixed with hard `Color.white.opacity(0.12)` track (`:42`) and `0.08` chip fills (`:305`) — invisible on a light menu bar. Use `Color.primary.opacity(...)` or `.quaternary`.
- `menuRow` (`:324-338`) has no hover highlight → the list feels dead next to real NSMenu rows.
- `modeToggle` (`:312-322`) and `menuRow` have `.help` only — no `accessibilityLabel` for icon-only shuffle/repeat.
- Chip strip is a third copy of the chip component.

#### `NowPlayingView.swift`
**Good** — backdrop correctly in `.background { }` (`:107-142`) with dominant-colour wash cross-fade; `ScrubberSection` isolated for 4Hz re-renders (`:387-393`); custom `ScrubberSlider` with live drag, ←/→ nudge, VoiceOver adjustable (`:2209-2282`); mute-restore volume (`:495-530`); sleep timer with countdown + `updatesFrequently` trait; queue rows with `skipTo`, drag-reorder + red insertion bar, ⋯ menu, context menu, `Theme.Motion.list` + reduce-motion (`:1893-1961`); karaoke lyrics with 30fps extrapolation, tap-to-seek, fullscreen, translation; X-Ray cards; Tune popover with `FlowLayout`; layered Esc (`:155-163`).
**Gaps**
- **14 controls in one transport row** (`:408-488`): ♥, shuffle, −15, ⏮, ▶, ⏭, +30, repeat, rate, AirPlay, sleep, playlist, ⋯. At the 980pt minimum window the left column is ≈536pt wide; 13 × 40pt + 16pt spacing ≈ 728pt → overflow/clipping. Apple Music / YTM keep 5 primary controls on the main row and demote the rest.
- **Play button is a `ZStack.onTapGesture`** (`:452-464`), not a `Button`: no pressed state, no keyboard activation via focus, no focus ring.
- **Artwork fixed at 320** (`:281`) regardless of window size — in native fullscreen the left column is ~1000pt wide with a 320pt cover. Scale to `min(440, availableWidth − 64)`.
- `heroMedia` uses `.fit` inside a 320 square with a square clip + shadow (`:277-283`) → 16:9 video thumbnails show transparent letterbox bars inside a rounded square with a square shadow. Tiles use `.fill`.
- "Watch video" pill is always visible over the art (`:284-307`) — competes with the cover; make it hover-reveal like the tile overlays.
- Four hard-coded animations, none reduce-motion-aware, none via `Theme.Motion` (`:106,141,320,1715`).
- **Queue rows have no hover state** (`:2081`) and the ⋯ menu is always visible (`:2042-2067`) — a wall of ellipses in a 348pt pane; `TrackRow` hover-reveals its cluster. No drag-handle glyph → reorder is undiscoverable.
- **No keyboard traversal in Up Next** (↑/↓/↵/⌫) — Search and CommandPalette have it; the queue is the list most worth it (`skipTo` on ↵, `removeFromQueue` on ⌫ — both existing API, no policy change).
- History rows: `0.6` opacity on a row whose text is already 0.75 → ~0.45 effective (`:1910`); the rows are interactive.
- Up Next header packs 4 chips (Save / Clear / Build / Tune) + label into 348pt (`:836-947`); the comment at `:863-865` admits wrapping. Collapse Save/Clear/Build into one ⋯ menu; keep Tune.
- Side-pane tab buttons (`:317-334`) lack `.isSelected` trait; `moreMenu`, `addToPlaylistMenu`, `playbackRateMenu`, `audioOutputButton` have `.help` but no `accessibilityLabel` (sleep timer does, `:581`).
- **Fullscreen lyrics reuse side-pane type sizes** (`karaokeLine:1753,1756` 14/13pt) inside a 640pt column (`:1679`) — reads as a widget, not Apple Music's ~28pt lyric screen. Active-line emphasis (14 semibold vs 13 regular) is weak.
- `.help("Jump to this line")` on every lyric line (`:1771`) → tooltip spam while reading.
- Empty/loading hints are bare 12pt text (`emptyHint:2138`, "Looking for related tracks…" `:1807` with no spinner) — inconsistent with `EmptyState` and the lyrics spinner (`:1171-1179`).
- Volume slider `.controlSize(.mini)` (`:521`) in the full player; `.small` in the mini bar — inverted.
- Doc comment `:8` mentions a "Now Playing" title in the top bar; `topBar` (`:189-213`) has only the Close capsule — stale.

---

## B. Top 12 improvements (ranked by impact)

| # | Title | Evidence | Concrete change | Effort | Risk |
|---|---|---|---|---|---|
| 1 | **Keep `MainTabs` mounted while Now Playing is open** | `RiffApp.swift:352-363` `if/else` swap; Explore `:49` re-skeletons, Library `.task(id:)` refetches, Search refocuses on every close. | In `RootView`, render `ZStack { MainTabs + MiniPlayer; if isFullPlayerOpen { NowPlayingView().transition(...) } }`; add `.accessibilityHidden(isFullPlayerOpen)` and `.allowsHitTesting(!isFullPlayerOpen)` to the tabs layer. NowPlaying is opaque (`Color.black` in its `.background{}`), so no leak; the original leak was the backdrop-inflation bug (memory note). | M | Med — re-verify in native fullscreen with a `GeometryReader` probe per the memory note. |
| 2 | **Split the Now Playing transport into primary + secondary rows** | `NowPlayingView:408-488`, 14 controls, overflow at 980pt. | Row 1 (spacing 20): shuffle, ⏮, ▶ (64pt red), ⏭, repeat. Row 2 (spacing 14, 0.6 opacity icons): ♥, −15, +30, rate, sleep, AirPlay, playlist, ⋯. Wrap ▶ in `Button(.plain)` with `.scaleEffect(pressed ? 0.94 : 1)` via `ButtonStyle`. Volume stays below. | M | Low — no bridge calls change. |
| 3 | **Ship the token layer and adopt it** | `Theme.surface/surfaceHover` 0 uses; 11 radii; opacity 0.45–0.9; 19× `Divider().background`. | Add to `Theme`: `Radius { tile 12, card 10, row 8, thumb 6, chip capsule }`, `Text { primary 1.0, secondary 0.85, tertiary 0.6, disabled 0.4 }`, `Hairline` view, `Spacing { gutter 24, section 32, rail 16 }`. Replace raw literals in the audited files (mechanical). | M | Low — pure refactor; visual diff is intentional (contrast fixes). |
| 4 | **One `Chip` component + shared selected semantics (red)** | 8 chip implementations; Search selected = white (`SearchView:795`) vs Home red. No hover on Search chips. | `Components/Chip.swift`: `Chip(label, isSelected, style: .primary/.secondary/.mini, systemImage?, action)` with hover (`Theme.surfaceHover`), `.isSelected` trait, `.help`. Replace MoodChipPill, FilterChip, RefinementChip, recent/suggestion chips, miniChip ×2, Tune chip. | M | Low. |
| 5 | **Loading skeletons on Library and Detail; cache-first Explore** | Library flashes "No liked songs yet" (`LibraryView:234`); Detail is a spinner (`DetailView:126`); Explore skeleton every visit (`ExploreView:49`). | Extract `CarouselSkeleton` (from `HomeSkeleton`) + add `GridSkeleton` (adaptive 180 tiles) and `DetailSkeleton` (220 cover + 3 bars + 8 row bars). Library: `@State loading`, clear `items` on section change. Explore: add `ExploreFeedCache` mirroring `HomeFeedCache` (same struct, different key). Gate `repeatForever` pulse on reduce-motion (static 0.08 fill instead). | M | Low. |
| 6 | **Search input + kind filter re-skin to Riff style** | `SearchView:176` `.roundedBorder`; `LibraryView:152-163` capsule exists. | Extract `SearchField(text:, placeholder:, isFocused:)` from Library's capsule (magnifier, 36pt tall, `Theme.surface`, focus ring `Theme.red` 2pt, trailing `xmark.circle.fill` clear, Esc clears/blurs). Use in Search, Library filter, CommandPalette. Kind filters → `Chip(.primary)`. | S | Low. |
| 7 | **Queue rows: hover, hover-revealed ⋯, grip, keyboard** | `NowPlayingView:1981-2083, 1893-1961`; no hover, always-on ⋯, no ↑↓↵⌫. | `queueRow`: `@State hovering` → background `Theme.surfaceHover`; `⋯` and a `line.3.horizontal` grip at `opacity(hovering ? 1 : 0)` (keep a11y label always). Add `@FocusState focusedQueueId` + `.focused(...)` per row; `.onKeyPress(.upArrow/.downArrow)` move + `scrollTo`, `.return` → `skipTo(item:)`, `.delete` → `removeFromQueue`. All existing bridge API; no `QueuePolicy` change. | M | Low — behaviour lock untouched (`skipTo`/`removeFromQueue` already row actions). |
| 8 | **Fullscreen lyrics at display size + stronger active line** | `karaokeLine:1753,1756` 14/13pt reused in `fullscreenLyricsView:1643-1684`. | Add a `lyricScale: CGFloat` parameter (side pane 1.0, fullscreen 2.0) or an `@Environment` key; active line `size 15 semibold` (pane) / `30 bold` (fullscreen), inactive `13/26 regular`, `Theme.Motion.subtle` on active-index change. Drop `.help` on lines; add `.accessibilityHint("Double tap to jump here")` instead. | S | Low. |
| 9 | **Detail page backdrop, circular artist art, 24pt gutter, capsule CTAs** | `DetailView:136` flat black; `:155` square for artists; `:99-720` 32pt; `:183-202` stock buttons. | `.background { ZStack { Color.black; AsyncImage(art).scaledToFill().blur(80).opacity(0.35); LinearGradient(dominant.opacity(0.45) → .clear) }.ignoresSafeArea() }` (reuse `DominantColor.extract`); `clipShape(item.kind == .artist ? Circle : RoundedRectangle(Theme.Radius.card))`; padding 24; add `PrimaryCapsuleButtonStyle` (red, white text) + `SecondaryCapsuleButtonStyle` (`Theme.surface`, hairline) in Theme and use them in Detail, TopResultCard, EmptyState, SignInNudge, Library anonymous state. | M | Med — backdrop must stay in `.background{}` (fullscreen inflation). |
| 10 | **Contrast floor 0.85 for secondary text; 0.6 only for tertiary** | `DetailView:701,715` 0.55; `EmptyState:46` 0.6; Search rows 0.7/0.75; history rows 0.45 effective. | Apply `Theme.Text.secondary` to subtitles/durations; `tertiary` only for track numbers, eyebrows, hints. History rows: fade artwork to 0.6 but keep text at 0.85. | S | Low. |
| 11 | **Library: chip section selector, Liked/History as track list, grid keyboard nav** | `LibraryView:137-146` segmented; tiles for songs; no ←→↑↓. | Replace `Picker` with `Chip(.primary)` row (same as Search). For `.liked`/`.history` render `TrackRow`-style list (index, 44pt art, title, `ArtistLinkLine`, duration, hover ♥/⋯). Grid: `@FocusState` + `.onKeyPress` for arrows computing column count from width (`GeometryReader`), reuse `ThumbnailButton.externalFocus`. `GridItem(.adaptive(minimum: 180, maximum: 180))`. | L | Low–Med (TrackRow must move from `private` in DetailView to Components). |
| 12 | **Mini bar parity: ♥ + queue button, a11y labels, `ArtistLinkLine`, live scrubber** | `MiniPlayerView:70-82,157-168`. | Add ♥ (`toggleLike`, `⌘L` exists) and `list.bullet` button (`isFullPlayerOpen = true`; expose `preferredBottomTab` in env so it opens on Up Next); mirror `help` into `accessibilityLabel`; subtitle → `ArtistLinkLine(fontSize: 12, baseOpacity: 0.85)`; progress strip → thin `ScrubberSlider` variant (live drag + hover time). Also add `.accessibilityHidden(!isHovering)` to Floating's transport. | S | Low. |

---

## C. Quick wins (≤ 30 min each)

- [ ] `Theme.Hairline` view; replace all 19 `Divider().background(...)` sites (`NowPlayingView:336,1010`, `DetailView:94,412`, `CommandPalette:44,74`, Settings, EditPlaylistSheet).
- [ ] `MiniPlayerView:157-168` `controlButton`: add `.accessibilityLabel(help)`; `MenuBarMiniPlayer:312-322` `modeToggle` likewise.
- [ ] `MiniPlayerView:51` → replace `Color.gray.opacity(0.2)` with the `music.note`-on-`Theme.surface` placeholder used by queue rows (`NowPlayingView:1996-2001`); `:66` `.secondary` → `.white.opacity(0.85)`.
- [ ] `DetailView:701,715` opacity 0.55 → 0.85 (subtitle) / 0.75 (duration); `EmptyState:46` 0.6 → 0.75.
- [ ] `DetailView:155` artist header → `Circle()` clip when `item.kind == .artist`.
- [ ] `DetailView:99,114,243,415,720` horizontal padding 32 → 24.
- [ ] `DetailView:96` `Text("No tracks")` → `EmptyState(systemImage: "music.note.list", title: "No tracks", subtitle: …)`.
- [ ] `DetailView:666` pass `initiallyLiked: item.id == "LM"`-page flag into `TrackRow` so Liked Songs rows start filled.
- [ ] `DetailView:742`, `FloatingMiniPlayer:103`, `NowPlayingView:106,141,320` → wrap in `reduceMotion ? nil : Theme.Motion.subtle/panel`; read `@Environment(\.accessibilityReduceMotion)`.
- [ ] `HomeView:322`, `ExploreView:111` skeleton pulse → skip `repeatForever` when reduce-motion; render static 0.08.
- [ ] `SearchView:433-446` `moveFocus`: wrap `resultList` in `ScrollViewReader`, `.id(item.id)` per row, `proxy.scrollTo(next, anchor: .center)`.
- [ ] `SearchView:418-424`: add `.onKeyPress(.return, modifiers: .command)` → `env.player.addToQueueEnd(item:)` + toast (matches the documented `⌘↵`); `.onKeyPress(.escape)` → `focusedResultId = nil; searchFieldFocused = true`.
- [ ] `SearchView:785-801` FilterChip: selected fill `Theme.red` + `.white` text (match Home), add `onHover` and `.accessibilityAddTraits(selected ? .isSelected : [])`.
- [ ] `SearchResultRow:135-138`, `TopResultCard:276-279`, `DetailView:698-702` → `ArtistLinkLine(subtitle:, primaryArtistId: item.artistId, fontSize: 12, baseOpacity: 0.85)`.
- [ ] `NowPlayingView:317-334` tab buttons: `.accessibilityAddTraits(bottomTab == t ? .isSelected : [])`; add `accessibilityLabel` to `moreMenu`, `addToPlaylistMenu`, `playbackRateMenu`, `audioOutputButton`.
- [ ] `NowPlayingView:1771` remove `.help("Jump to this line")` from every lyric line.
- [ ] `NowPlayingView:1807` "Looking for related tracks…" → `ProgressView().controlSize(.small)` + text like lyrics loading (`:1171-1179`).
- [ ] `NowPlayingView:284-307` "Watch video" → hover-reveal (`@State hovering` on `heroMedia`, `.transition(.opacity)`).
- [ ] `NowPlayingView:521` volume `.controlSize(.mini)` → `.small`.
- [ ] `NowPlayingView:452-464` play control → `Button(.plain)` (keeps `Task { togglePlay() }`), add `.keyboardShortcut(.space, modifiers: [])` is already a menu command — just fix focusability.
- [ ] `ExploreView:72-84` header 28pt → 32pt (or delete header for parity with Home/Search/Library); `ExploreSkeleton:101-103` add the missing subtitle bar or delete in favour of a shared `CarouselSkeleton`.
- [ ] `ExploreView:28-37` add `EmptyState` when `!loading && sections.isEmpty && moods.isEmpty && errorMessage == nil`.
- [ ] `LibraryView:255` `GridItem(.adaptive(minimum: 180, maximum: 180), spacing: 16)`.
- [ ] `LibraryView:346-367` anonymous state → `EmptyState(systemImage: "person.crop.circle.badge.exclamationmark", title: "Sign in to unlock your library", subtitle: …, cta: .init("Sign In with Google", systemImage: "person.crop.circle") { … })`; drop `.tint(.red)`.
- [ ] `LibraryView:462-496` followed rail → `HomeSectionRow(section: HomeSection(id: "library.followedReleases", title: "New from artists you follow", items: followedReleases))`.
- [ ] `LibraryView:220` rail spacing 24 → 32.
- [ ] `FloatingMiniPlayer:184` chip font 9 → 11; `:34` placeholder → glyph on `Theme.surface`; add `.accessibilityHidden(!isHovering)` to the transport ZStack.
- [ ] `MenuBarMiniPlayer:42,305` → `Color.primary.opacity(0.12)` / `Color.primary.opacity(0.08)` so the popover survives Light appearance; `menuRow:324-338` add `@State hovering` → `Color.primary.opacity(0.06)` background, radius 6.
- [ ] Extract `PointingHandOnHover` modifier (`NSCursor.pointingHand.set()` / `NSCursor.arrow.set()`) and use in `MiniPlayerView:40`, `FloatingMiniPlayer:126`, `MenuBarMiniPlayer:57`.
- [ ] Extract `extension PlayerBridge.Track { var asMediaItem: MediaItem }` and collapse the three `nowPlayingMenuItems` (`MiniPlayerView:141`, `FloatingMiniPlayer:145`, `NowPlayingView:683`); extract `VolumeGlyph(volume:)` for the three speaker-icon ternaries.
- [ ] `NowPlayingView:8` fix the stale doc comment ("Now Playing" title no longer in `topBar`).

---

### Verification plan for whoever implements
1. Build via `xcodegen generate` + Xcode; run `./tools/harness/run.sh` (none of the above touches `Sources/Audio/` or `player-bridge.js`, but #7 adds UI call sites of existing bridge methods — the guard counts `PlayerBridge` internals only).
2. Geometry probe (memory note) on `NowPlayingView` and the new Detail backdrop in native fullscreen at 1512×949.
3. Test at 980×640 (min), 1280×800, native fullscreen; System Settings → Accessibility → Reduce Motion on/off; VoiceOver pass over Mini bar, transport, queue, Search results.
4. Toggle system Light appearance and open the menu-bar popover.
