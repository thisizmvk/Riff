# Contributing to Riff

Thanks for the interest. Riff is a small project with a few firm
architectural rules — once you know them, the codebase reads cleanly.
This file is the on-ramp.

## What Riff is, briefly

A native macOS YouTube Music client. SwiftUI on top, hidden offscreen
WKWebView on the bottom, native InnerTube client in the middle. The
WKWebView exists *only* as the audio engine — no DOM is ever shown to
the user. Every browse surface, list, grid, detail page, and player UI
is real SwiftUI fed by `InnerTubeClient`.

This is the single thing that distinguishes Riff from "embed
music.youtube.com in a webview" wrappers. **PRs that surface the
WebView outside the sign-in flow will be rejected.** See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full rationale.

## Build setup

```sh
brew install xcodegen
git clone https://github.com/<your-fork>/Riff.git
cd Riff
xcodegen generate
open Riff.xcodeproj
```

You need **Xcode 16+** — the generated project uses the Xcode 16
project format (objectVersion 77), which Xcode 15 can't open.

`Riff.xcodeproj` is **gitignored**. [`project.yml`](project.yml) is the
source of truth. If you add a source file, no project.yml change is
needed — `xcodegen` picks up everything under `Sources/`. If you add a
build setting or capability, edit `project.yml` and re-run `xcodegen`.

## Running tests

```sh
xcodebuild -scheme Riff -destination 'platform=macOS' test
```

The test target hits `InnerTubeClient`'s parsers + `QueueManager` +
`BrowseIdResolver` directly. Network is never mocked — parser tests
use hand-crafted minimal JSON; resolver tests use a 100ms-timeout
URLSession to drive past unreachable endpoints quickly.

If you change a renderer-walking parser, **add a fixture test.**
Renderer drift is the highest-likelihood breakage source.

## The queue harness and git hooks

The playback queue follows a single-authority design (the hidden page
owns the queue) with a behavior contract in
[`docs/QUEUE-DESIGN.md`](docs/QUEUE-DESIGN.md). It is fenced by static
guards and a standalone logic harness that need no Xcode project:

```sh
./tools/harness/run.sh
```

Run it before committing to `Sources/Audio/`,
`Resources/player-bridge.js`, or `tools/harness/` — or let git do it
for you by enabling the repo's hooks once per clone:

```sh
git config core.hooksPath .githooks
```

The pre-commit hook runs the full harness when the queue core is
staged, and the (sub-second) static guards when anything else under
`Sources/` is staged — they catch break classes plain `swiftc -parse`
can't, like duplicate type declarations.

## Code style

- **Comments explain *why*, not *what*.** A comment paraphrasing the
  next three lines adds noise. A comment explaining "this exists
  because YT Music returns shape X 90% of the time but shape Y in
  $edge_case" is gold.
- **No new dependencies in `InnerTubeClient` or `PlayerBridge`.** They
  stay zero-dependency. Adding one needs an ADR (open an issue with
  `[ADR]` in the title; we'll discuss before implementation).
- **Strict concurrency on.** The project builds in the Swift 5.10
  language mode with `SWIFT_STRICT_CONCURRENCY: complete` (see
  `project.yml`) — full concurrency checking, not yet the Swift 6
  language mode. Nothing should fight the type system.
- **MainActor everywhere by default.** PlayerBridge, AppEnvironment,
  views — all MainActor. Drop to detached only with a clear reason.

## The protocol-rotation point

When Google changes the InnerTube protocol on us (every 6-18 months
empirically), the symptom is "all browse calls return empty
sectionLists." The fix is bumping
`InnerTubeClient.clientVersion`. Don't change it for any other reason
— a stale value can also be the *cause* of intermittent issues, so
flipping it casually muddies debugging.

## Things to avoid

- **Surfacing the WKWebView outside the sign-in sheet.** Rule #1.
- **Extracting raw audio streams** (yt-dlp, `/player` endpoint).
  Breaks Premium DRM and YouTube ToS; legally risky and architecturally
  outside the project's scope.
- **Telemetry of any kind in MVP.** MetricKit is on (Apple's built-in
  crash + perf reporter, all stays local) but we never wire third-party
  analytics. If you want to add Sentry/Mixpanel/etc., open an ADR.
- **Renaming `clientVersion` casually.** See above.
- **Adding files to `Riff.xcodeproj/`.** It's a generated artifact.
  Edit `project.yml`.

## Pull request flow

1. Fork, branch from `main`.
2. Make your change. Keep it focused — one logical thing per PR.
3. `xcodebuild test` should pass locally — and if you touched the
   queue core (`Sources/Audio/`, `Resources/player-bridge.js`,
   `tools/harness/`), `./tools/harness/run.sh` too.
4. Open the PR with a description that says **why**, not just **what**
   (the diff already shows the what).
5. CI runs on macos-15 runners with Xcode 16: the queue harness job on
   every push to any branch, the full build-and-test job on pushes to
   `main` and PRs targeting `main`.

## License note

Riff is **AGPL-3.0**. By submitting a PR you agree your contribution
is licensed under the same terms. Don't paste code from other projects
unless their license is GPL-compatible.
