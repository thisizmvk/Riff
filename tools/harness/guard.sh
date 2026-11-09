#!/bin/bash
# Static behavior guards for the queue core. These freeze the surfaces
# that caused every queue regression this project has had. A failure
# here means an enhancement re-introduced a known-bad pattern OR added a
# navigation/force-play site without updating the allowlist below —
# both should be conscious decisions, reviewed against
# docs/QUEUE-DESIGN.md, not side effects.
#
#   ./tools/harness/guard.sh              check this checkout
#   ./tools/harness/guard.sh --self-test  prove every guard still fires
set -u
# RIFF_GUARD_ROOT is set only by --self-test (below), to point the
# guards at a scratch copy with one violation injected.
REPO="${RIFF_GUARD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
JS="$REPO/Resources/player-bridge.js"
PB="$REPO/Sources/Audio/PlayerBridge.swift"
QM="$REPO/Sources/Audio/QueueManager.swift"
fail=0
say() { echo "GUARD FAIL: $1"; fail=1; }
# Match CODE only — comment lines legitimately mention the banned
# patterns while explaining why they are banned.
COMMENT_LINE='^[[:space:]]*(//|\*|/\*)'
code_has() { grep -vE "$COMMENT_LINE" "$2" | grep -qE "$1"; }
# Number of CODE lines in file $2 matching $1 (prints 0 when none).
code_count() { grep -vE "$COMMENT_LINE" "$2" | grep -cE "$1"; }
# Same, summed over every Swift file under Sources/.
swift_code_count() {
  local total=0 c f
  while IFS= read -r f; do
    c=$(code_count "$1" "$f")
    total=$((total + c))
  done < <(find "$REPO/Sources" -name '*.swift')
  echo "$total"
}
# A hard page load from JS: assigning location.href, or location
# assign / replace / reload. (`new URL(location.href)` is a read.)
HARD_NAV_RE='location\.(href[[:space:]]*=[^=]|assign\(|replace\(|reload\()'

# ── Self-test ──────────────────────────────────────────────────────────
# A guard whose regex drifts narrower keeps printing "OK" forever. This
# copies the guarded files into a scratch tree, checks the clean copy
# passes, then injects one known-bad pattern at a time and requires a
# GUARD FAIL for each. Scratch dirs are left under $TMPDIR (see run.sh).
if [ "${1:-}" = "--self-test" ]; then
  SELF="$REPO/tools/harness/guard.sh"
  FX="$(mktemp -d "${TMPDIR:-/tmp}/riff-guard-selftest.XXXXXX")"
  FX_PB="$FX/Sources/Audio/PlayerBridge.swift"
  FX_QM="$FX/Sources/Audio/QueueManager.swift"
  FX_JS="$FX/Resources/player-bridge.js"
  mkdir -p "$FX/Sources/Audio" "$FX/Resources"
  reset_fixture() { cp "$PB" "$FX_PB"; cp "$QM" "$FX_QM"; cp "$JS" "$FX_JS"; }
  run_fixture() { RIFF_GUARD_ROOT="$FX" bash "$SELF" 2>&1; }
  st_fail=0
  st_cases=0
  # The mutation for a case is applied by the caller; this runs the
  # guards on it, records the verdict, and restores the clean copy.
  expect_caught() {
    local out
    st_cases=$((st_cases + 1))
    if out=$(run_fixture); then
      echo "GUARD SELF-TEST FAIL: not caught — $1"
      st_fail=1
    elif ! printf '%s\n' "$out" | grep -q "GUARD FAIL"; then
      echo "GUARD SELF-TEST FAIL: exited non-zero without a GUARD FAIL line — $1"
      st_fail=1
    fi
    reset_fixture
  }

  reset_fixture
  if ! out=$(run_fixture); then
    echo "GUARD SELF-TEST FAIL: the unmodified copy does not pass:"
    printf '%s\n' "$out"
    exit 1
  fi

  printf '%s\n' 'player.playVideoAt(3);' >> "$FX_JS";                         expect_caught "#1 playVideoAt in the JS"
  printf '%s\n' 'rows[i].click();' >> "$FX_JS";                               expect_caught "#2 positional row click"
  printf '%s\n' 'let d = Dictionary(uniqueKeysWithValues: pairs)' >> "$FX_QM"; expect_caught "#3 Dictionary(uniqueKeysWithValues:)"
  printf '%s\n' '        await navigate(url)' >> "$FX_PB";                     expect_caught "#4 extra 'await navigate('"
  printf '%s\n' '        await self.navigate(url)' >> "$FX_PB";                expect_caught "#4 'await self.navigate(' spelling"
  printf '%s\n' '        await self?.navigate(url)' >> "$FX_PB";               expect_caught "#4 'await self?.navigate(' spelling"
  printf '%s\n' '        await eval("window.musicBridge.navigate(u)")' >> "$FX_PB"; expect_caught "#4b direct musicBridge.navigate eval"
  printf '%s\n' '        await eval("location.href = next")' >> "$FX_PB";      expect_caught "#4b raw location.href from Swift"
  printf '%s\n' 'if (fallbackUrl) location.href = fallbackUrl;' >> "$FX_JS";   expect_caught "#4c extra JS location.href assignment"
  printf '%s\n' 'location.replace(next);' >> "$FX_JS";                        expect_caught "#4c JS location.replace"
  printf '%s\n' '        await self?.play(item: head, clearQueue: false)' >> "$FX_PB"; expect_caught "#5 extra play(item:) site"
  sed 's/QueuePolicy\.advance(/QueuePolicyGone.advance(/g' "$PB" > "$FX_PB";   expect_caught "#6 QueuePolicy.advance delegation removed"
  sed 's/var isPageDrivenContext/var isPageDrivenCtx/' "$PB" > "$FX_PB";       expect_caught "#7 isPageDrivenContext removed"
  printf '%s\n' 'struct GuardSelfTestDup {}' 'struct GuardSelfTestDup {}' >> "$FX_QM"; expect_caught "#8 duplicate type declaration"
  printf '%s\n' '@MainActor' '/// doc' 'func guardSelfTest() {}' >> "$FX_QM";  expect_caught "#9 attribute split from its declaration"

  [ "$st_fail" -eq 0 ] || { echo "Guard self-test FAILED — a guard no longer fires on the pattern it bans."; exit 1; }
  echo "guard self-test OK ($st_cases injected violations caught)"
  exit 0
fi

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
#    Code lines only; `await self.navigate(` and `await self?.navigate(`
#    count too (a fixed-string match let those spellings through).
EXPECTED_NAVIGATE=5
n=$(code_count 'await[[:space:]]+(self\??\.)?navigate\(' "$PB")
[ "$n" -eq "$EXPECTED_NAVIGATE" ] || say "PlayerBridge has $n 'await navigate(' sites (expected $EXPECTED_NAVIGATE) — a navigation was added/removed; review against the single-authority contract"

# 4b. PlayerBridge.navigate(_:) is Swift's only way into a page load. A
#     direct eval of musicBridge.navigate or of location.href would
#     bypass the count above.
EXPECTED_BRIDGE_NAVIGATE=1
bn=$(swift_code_count 'musicBridge\.navigate\(')
[ "$bn" -eq "$EXPECTED_BRIDGE_NAVIGATE" ] || say "Sources has $bn 'musicBridge.navigate(' sites (expected $EXPECTED_BRIDGE_NAVIGATE, inside PlayerBridge.navigate(_:)) — route page loads through that wrapper"
sn=$(swift_code_count "$HARD_NAV_RE")
[ "$sn" -eq 0 ] || say "Swift evaluates a raw page load (location.href= / assign / replace / reload) on $sn line(s) — route it through PlayerBridge.navigate(_:)"

# 4c. The JS side's own hard navigations, invisible to the Swift counts:
#       musicBridge.navigate() · the .ended pending-URL advance
EXPECTED_JS_NAV=2
jn=$(code_count "$HARD_NAV_RE" "$JS")
[ "$jn" -eq "$EXPECTED_JS_NAV" ] || say "player-bridge.js has $jn hard page loads (location.href= / assign / replace / reload; expected $EXPECTED_JS_NAV) — a reload path was added/removed; review against the single-authority contract"

# 5. Force-play sites (play(item:) callers) are the other reload path.
#      playTracks · next() 3b · startRadio · skipTo fallback ·
#      .ended fallback · trackChanged enforcement
#    PlayerBridge-internal only. play(item:) calls in UI/ and Intents/
#    are the user's own "play this" gestures and are not frozen here.
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
