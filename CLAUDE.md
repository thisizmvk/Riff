# Riff — repo guide for Claude Code

Repo for an open-source, native macOS YouTube Music client. SwiftUI front, hidden WKWebView audio engine, InnerTube data layer. See [`README.md`](README.md), [`PLAN.md`](PLAN.md), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md).

## Architectural rule (load-bearing)

**The WKWebView is never visible after the initial sign-in sheet.** Every browse surface, list, grid, detail page, and player UI is real SwiftUI fed by `InnerTubeClient`. Tapping any thumbnail invokes `PlayerBridge` directly — no DOM, no JS click simulation. This is the single thing that distinguishes this app from Kaset; reviewers must reject any PR that surfaces the WebView outside the sign-in flow.

## Repo layout

```
Sources/
  App/                @main + AppEnvironment
  UI/                 SwiftUI views (Home, Search, Library, Player, Components)
  Data/InnerTube/     Native Swift InnerTube client + endpoints + models
  Data/Auth/          WKWebsiteDataStore ↔ HTTPCookieStorage bridge
  Audio/              PlayerBridge, HiddenPlayerWebView, NowPlayingCenter
Resources/
  player-bridge.js    Injected into music.youtube.com; exposes window.musicBridge
Tests/                XCTest target
docs/                 ARCHITECTURE.md, PRODUCT_SPEC.md
.claude/              Agents, orchestration, reference screenshots
project.yml           XcodeGen source of truth (Riff.xcodeproj is generated)
```

## Build

```sh
brew install xcodegen
xcodegen generate
open Riff.xcodeproj
```

`Riff.xcodeproj` is .gitignored. `project.yml` is the source of truth.

## Cortex agents available in this repo

Imported from [thisizmsk-png/claude-cortex](https://github.com/thisizmsk-png/claude-cortex) under `.claude/agents/`:

| Agent | Role | When to invoke |
|---|---|---|
| `krishna` | Strategic CEO | "Should we build feature X?" — vs roadmap and Phase scope |
| `draupadi` | Product Manager | PRD writing, MVP scoping, user-pain traceability |
| `arjuna` | Principal SDE | ADRs, system design, architecture review |
| `nakula` | Senior Frontend Engineer | UI quality, design system, pixel-perfection |
| `duryodhana` | Red Team | Adversarial review of design or proposal |
| `bhishma` | Security Engineer | Security review, threat modelling |
| `vidura` | QA Engineer | Test strategy, quality gates |
| `hanuman` | DevOps / SRE | CI/CD, release engineering |

## Orchestration topologies

Under `.claude/orchestration/`:

- **`topologies/chakravyuha.yaml`** — parallel DAG. Use for UI PRs: run `nakula` + `critique` + `design-auditor` + `polish` concurrently against `.claude/refs/ytm-ios/` reference screenshots.
- **`topologies/vyuha.yaml`** — sequential pipeline.
- **`workflows/feature-development.yaml`** — canonical: requirements → design → adversarial review → revision → impl → test → security → deploy.

## Reference screenshots

Drop iPhone YT Music screenshots in `.claude/refs/ytm-ios/` per its README. Image files are gitignored. UI agents read these as the design ground truth.

## Queue core — behavior lock (load-bearing)

The playback queue follows a **single-authority** design: the hidden
page owns the queue; Riff is a remote control and a lens. The intended
behavior is a contract — see `docs/QUEUE-DESIGN.md` ("Behavior
contract") — encoded as a pure decision table in
`Sources/Audio/QueuePolicy.swift`, tested by `tools/harness/run.sh`,
and fenced by `tools/harness/guard.sh`.

- Any change deciding WHETHER to navigate, force-play, enforce, mirror,
  or shuffle locally goes in `QueuePolicy` **with a table row** — not
  inline in `PlayerBridge`.
- Adding a navigation or `play(item:)` call site fails the static
  guard until its allowlisted count is bumped with a justification.
- Never `playVideoAt(index)`; never click page rows by position.
- Run `./tools/harness/run.sh` before committing to `Sources/Audio/`,
  `Resources/player-bridge.js`, or `tools/harness/` (or
  `git config core.hooksPath .githooks`).

## Things to avoid

- Surfacing the WKWebView outside the sign-in sheet (architectural rule above).
- Extracting audio streams (yt-dlp / `/player`) — breaks Premium DRM and ToS.
- Adding telemetry of any kind in MVP.
- Adding dependencies without an ADR — InnerTubeClient and PlayerBridge stay zero-dependency.
- Renaming the `clientVersion` constant in `InnerTubeClient` casually — it's the single rotation point when Google changes the protocol; bump only with a CI signal.

## Working notes

- The `clientName=WEB_REMIX` and `clientVersion` constants in `InnerTubeClient.swift` mimic the YT Music web app. When Google rotates protocol, this is the dial we turn.
- `Resources/player-bridge.js` selectors (`.next-button`, `.previous-button`, `video`) are fragile. Treat them as a stable external API by keeping selectors in one place; if YT changes them, fix in the JS file, not in Swift.
- AGPL-3.0 forces downstream forks to remain open. Don't relax this without re-running the license decision through `krishna`.
