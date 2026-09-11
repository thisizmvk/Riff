#!/bin/bash
# Standalone logic-test harness — runs WITHOUT Xcode project generation,
# so it works in sandboxed/CI environments where xcodebuild can't.
#
#   ./tools/harness/run.sh
#
# Covers:
#   - QueueManager two-region invariants (+ 5000-op fuzz)
#   - SmartShuffle.merge contract
#   - CookieImporter parsing
#   - player-bridge.js queue-mirror resolver against simulated page
#     store shapes (classic store, proxy-wrapped inst.store,
#     player-bar .queue variants, flat items, dedup, caps)
#
# The Swift harness compiles a copy of QueueManager with @Observable/
# @MainActor stripped (the macro plugin can't run sandboxed; the
# annotations are orthogonal to the logic under test).
#
# Scratch dirs are left behind under $TMPDIR (unique per run) — the OS
# reclaims them; deliberate, so no destructive cleanup runs here.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/riff-harness.XXXXXX")"

cp "$REPO/Sources/Data/InnerTube/Models/MediaItem.swift" "$WORK/"
cp "$REPO/Sources/Audio/PlayedHistoryStore.swift" "$WORK/"
cp "$REPO/Sources/Audio/SmartShuffle.swift" "$WORK/"
cp "$REPO/Sources/Audio/QueuePolicy.swift" "$WORK/"
cp "$REPO/Sources/Audio/PersonalizedShelves.swift" "$WORK/"
cp "$REPO/Sources/Data/Auth/CookieImporter.swift" "$WORK/"
cp "$REPO/tools/harness/MoveShim.swift" "$WORK/"
cp "$REPO/tools/harness/QueueLogicTests.swift" "$WORK/main.swift"
sed -e 's/^import Observation$//' -e 's/^@Observable$//' -e 's/^@MainActor$//' -e 's/@ObservationIgnored //' \
    "$REPO/Sources/Audio/QueueManager.swift" > "$WORK/QueueManager.swift"

echo "── Static behavior guards ──"
"$REPO/tools/harness/guard.sh"
# Prove the guards still fire: a regex that drifts narrower would keep
# printing OK forever, silently disabling its guard.
"$REPO/tools/harness/guard.sh" --self-test

echo "── Swift queue-logic harness ──"
if ! xcrun -sdk macosx swiftc -module-cache-path "$WORK/mc" \
    "$WORK/MediaItem.swift" "$WORK/PlayedHistoryStore.swift" "$WORK/QueueManager.swift" \
    "$WORK/SmartShuffle.swift" "$WORK/QueuePolicy.swift" "$WORK/PersonalizedShelves.swift" "$WORK/CookieImporter.swift" "$WORK/MoveShim.swift" "$WORK/main.swift" \
    -o "$WORK/harness" 2> "$WORK/build.err"; then
    grep -v "cache file" "$WORK/build.err" >&2 || true
    exit 1
fi
"$WORK/harness"

echo ""
echo "── JS bridge harness ──"
node "$REPO/tools/harness/js-harness.mjs" "$REPO/Resources/player-bridge.js"

echo ""
echo "── fieldcheck.sh fixtures ──"
# The field grader must count a page reload from BOTH build flavors:
# Release logs a bare "… ready", Debug echoes the payload
# ("… ready [\"event\": \"ready\"]"). A Debug-blind pattern once graded
# "0 reloads" as an artifact of the build configuration.
FC="$WORK/fieldcheck"
mkdir -p "$FC"
printf '%s\n' \
    '2026-09-10 12:00:00.000 Db Riff[123:4] [dev.riff.app:bridge] ready' \
    > "$FC/release.log"
printf '%s\n' \
    '2026-09-10 12:00:00.000 Db Riff[123:4] [dev.riff.app:bridge] ready ["event": "ready"]' \
    > "$FC/debug.log"
for flavor in release debug; do
    # Capture, then grep: `fieldcheck | grep -q` would EPIPE the script
    # under pipefail when grep exits at the first match.
    OUT="$("$REPO/tools/harness/fieldcheck.sh" "$FC/$flavor.log")"
    if ! printf '%s\n' "$OUT" | grep -q 'page reloads (ready): *1$'; then
        echo "FAIL: fieldcheck did not count the $flavor-build ready line as 1 reload"
        exit 1
    fi
done
# A log with no Riff[PID: lines (wrong --style, Console.app export) must
# explain itself and exit 2 — not die silently under set -e/pipefail.
: > "$FC/empty.log"
if OUT="$("$REPO/tools/harness/fieldcheck.sh" "$FC/empty.log" 2>&1)"; then
    echo "FAIL: fieldcheck accepted a log with no Riff[PID: lines"
    exit 1
elif ! printf '%s\n' "$OUT" | grep -q "no 'Riff\[PID:' lines"; then
    echo "FAIL: fieldcheck died without its no-PID explanation: $OUT"
    exit 1
fi
echo "fieldcheck fixtures OK (release ready, debug ready, no-PID log)"
