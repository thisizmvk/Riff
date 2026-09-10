#!/bin/bash
# Static behavior guards for the queue core. These freeze the surfaces
# that caused every queue regression this project has had. A failure
# here means an enhancement re-introduced a known-bad pattern OR added a
# navigation/force-play site without updating the allowlist below —
# both should be conscious decisions, reviewed against
# docs/QUEUE-DESIGN.md, not side effects.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
JS="$REPO/Resources/player-bridge.js"
PB="$REPO/Sources/Audio/PlayerBridge.swift"
QM="$REPO/Sources/Audio/QueueManager.swift"
fail=0
say() { echo "GUARD FAIL: $1"; fail=1; }
# Match CODE only — comment lines legitimately mention the banned
# patterns while explaining why they are banned.
code_has() { grep -vE '^[[:space:]]*(//|\*|/\*)' "$2" | grep -qE "$1"; }

# 1. Index-guessing into the page's player playlist played the WRONG
#    track (index spaces differ). Never again.
code_has "playVideoAt" "$JS" && say "player-bridge.js uses playVideoAt (index-space mismatch; use identity-matched row clicks)"

# 2. Row clicks must be identity-verified, never positional.
grep -qE "rows\[idx\]|rows\[i\]\.click" "$JS" && say "player-bridge.js clicks a queue row by position"

# 3. Duplicate-id trap in reorder.
code_has "uniqueKeysWithValues" "$QM" && say "QueueManager uses Dictionary(uniqueKeysWithValues:) (traps on duplicate ids)"

# 4. Every hard navigation is a page reload; in radio it re-rolls the
#    queue. Freeze the number of navigation sites — a new one must bump
#    this count AND justify itself in QUEUE-DESIGN.md.
#      play(videoId:) · playPlaylist · playByResolvingBrowseId (x3)
EXPECTED_NAVIGATE=5
n=$(grep -c "await navigate(" "$PB")
[ "$n" -eq "$EXPECTED_NAVIGATE" ] || say "PlayerBridge has $n 'await navigate(' sites (expected $EXPECTED_NAVIGATE) — a navigation was added/removed; review against the single-authority contract"

# 5. Force-play sites (play(item:) callers) are the other reload path.
#      playTracks · next() 3b · startRadio · skipTo fallback ·
#      .ended fallback · trackChanged enforcement
EXPECTED_PLAY_ITEM=6
m=$(grep -c "await play(item: \|await self?.play(item: \|await self.play(item: " "$PB")
[ "$m" -eq "$EXPECTED_PLAY_ITEM" ] || say "PlayerBridge has $m play(item:) call sites (expected $EXPECTED_PLAY_ITEM) — a force-play was added/removed; review against the single-authority contract"

# 6. Decision logic must stay in QueuePolicy (harness-tested), not
#    re-grow inline in PlayerBridge.
for fn in "QueuePolicy.advance(" "QueuePolicy.enforcementApplies(" "QueuePolicy.mirrorApplies(" "QueuePolicy.nextUsesPageNative(" "QueuePolicy.localShuffleAllowed(" "QueuePolicy.rowTapUsesPageJump(" "QueuePolicy.contextExhausted("; do
  grep -q "$fn" "$PB" || say "PlayerBridge no longer delegates to $fn — decision logic drifted out of the tested policy"
done

# 7. The mirror must never be skipped for page-driven radio (that
#    reintroduces the two-radios bug). The page-driven flag itself:
grep -q "var isPageDrivenContext" "$PB" || say "isPageDrivenContext removed"

# 8. Duplicate type declarations within a file. swiftc -parse (all the
#    sandbox can run) does not catch "invalid redeclaration" — a
#    patch that mis-anchored once duplicated two structs and broke the
#    real build. Cheap to catch here.
while IFS= read -r f; do
  dups=$(grep -oE "^(private |fileprivate |internal |public )?(final )?(struct|class|enum|actor) [A-Za-z_][A-Za-z0-9_]*" "$f" \
         | awk '{print $NF}' | sort | uniq -d)
  [ -n "$dups" ] && say "$f declares a type more than once: $(echo "$dups" | tr '\n' ' ')"
done < <(find "$REPO/Sources" -name '*.swift')

# 9. An attribute line (@ViewBuilder, @MainActor, …) immediately
#    followed by a doc-comment line means an insertion slid between an
#    attribute and its declaration — the attribute now binds to the
#    NEXT declaration ("only one result builder attribute" / "opaque
#    return type … no return statements"). Broke the real build twice.
while IFS= read -r f; do
  hit=$(awk 'prev ~ /^[[:space:]]*@[A-Za-z]+[[:space:]]*$/ && $0 ~ /^[[:space:]]*\/\/\// { print NR": "prev } { prev=$0 }' "$f")
  [ -n "$hit" ] && say "$f has an attribute separated from its declaration by a doc comment (line $hit)"
done < <(find "$REPO/Sources" -name '*.swift')

if [ "$fail" -ne 0 ]; then
  echo "Static guards FAILED — see docs/QUEUE-DESIGN.md (Behavior contract)."
  exit 1
fi
echo "static guards OK"
