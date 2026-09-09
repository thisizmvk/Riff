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
cp "$REPO/Sources/Data/Auth/CookieImporter.swift" "$WORK/"
cp "$REPO/tools/harness/MoveShim.swift" "$WORK/"
cp "$REPO/tools/harness/QueueLogicTests.swift" "$WORK/main.swift"
sed -e 's/^import Observation$//' -e 's/^@Observable$//' -e 's/^@MainActor$//' -e 's/@ObservationIgnored //' \
    "$REPO/Sources/Audio/QueueManager.swift" > "$WORK/QueueManager.swift"

echo "── Static behavior guards ──"
"$REPO/tools/harness/guard.sh"

echo "── Swift queue-logic harness ──"
if ! xcrun -sdk macosx swiftc -module-cache-path "$WORK/mc" \
    "$WORK/MediaItem.swift" "$WORK/PlayedHistoryStore.swift" "$WORK/QueueManager.swift" \
    "$WORK/SmartShuffle.swift" "$WORK/QueuePolicy.swift" "$WORK/CookieImporter.swift" "$WORK/MoveShim.swift" "$WORK/main.swift" \
    -o "$WORK/harness" 2> "$WORK/build.err"; then
    grep -v "cache file" "$WORK/build.err" >&2 || true
    exit 1
fi
"$WORK/harness"

echo ""
echo "── JS bridge harness ──"
node "$REPO/tools/harness/js-harness.mjs" "$REPO/Resources/player-bridge.js"
