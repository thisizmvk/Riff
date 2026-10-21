# Changelog

All notable changes to Riff are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Single-authority queue core: the hidden page owns the queue, Riff is a
  remote control and a lens. The behavior contract lives in
  `docs/QUEUE-DESIGN.md`, is encoded as a pure decision table in
  `QueuePolicy`, and is fenced by static guards plus a Swift/JS test
  harness (`tools/harness/`).
- Page-native queue edits: Play Next, Add to queue, remove, and row-tap
  jumps go through the page's own UI actions and are verified against
  the mirrored queue — no store dispatch, no positional clicks.
- Library completeness: playlists, albums, artists, podcasts, and
  history surfaces filled out with full pagination.
- Mounted tabs: Home / Search / Library stay alive when switched away
  from, so scroll position and loaded content survive tab changes.
- Cookie sync between the sign-in WKWebView data store and
  `HTTPCookieStorage`, keeping the native InnerTube client signed in
  without re-prompting.
- Graphite palette and a semantic design-token layer across the app.
- Floating mini player: bounded tile (220×200 … 600×600), artwork as
  background, floating window level applied when the view joins its
  window, and the user's chosen tile size preserved.
- Sandbox file-access entitlements for the lyric-card save panel
  (user-selected) and the diagnostics export to ~/Downloads.

### Changed
- Up Next header in Now Playing adapts instead of wrapping chips
  mid-word.
- Release workflow: version stamped from the tag, optional Developer ID
  signing + notarization, and a .dmg alongside the zip — with sha256
  checksums for both.

### Fixed
- Review findings across the queue core, auth, AI providers, and UI
  (hardened guards, harness self-test, CI supply-chain pinning among
  them).

## [0.1.0] - 2026-05-05

### Added
- Initial release: sign-in (Safari-UA WebView cookie flow), native
  Home / Search / Library tabs, click-any-thumbnail-to-play, full-screen
  Now Playing with synced lyrics and Up Next, album / artist / playlist
  detail pages, track context menus, keyboard shortcuts, macOS Now
  Playing integration and media keys — all real SwiftUI over a native
  InnerTube client, with the WKWebView hidden as the audio engine.

[Unreleased]: https://github.com/mvk24199/Riff/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mvk24199/Riff/releases/tag/v0.1.0
