#!/bin/bash
# Field verification of the single-authority queue against a captured
# bridge log. Grades the scenarios that gate Phase D (docs/QUEUE-DESIGN.md).
#
#   ./tools/harness/fieldcheck.sh [~/Downloads/riff-bridge.log] [--all]
#
# Capture the log with:
#   log stream --predicate 'subsystem == "dev.riff.app" AND category == "bridge"' \
#       --level debug --style compact | tee ~/Downloads/riff-bridge.log
#
# By default only the LAST app process in the file is graded (a relaunch
# starts a new PID); --all grades everything.
set -euo pipefail
LOG="${1:-$HOME/Downloads/riff-bridge.log}"
ALL="${2:-}"
[ -f "$LOG" ] || { echo "no log at $LOG"; exit 2; }

if [ "$ALL" = "--all" ]; then
    BODY="$(cat "$LOG")"
else
    PID="$(grep -o 'Riff\[[0-9]*:' "$LOG" | tail -1 | tr -dc '0-9')"
    BODY="$(grep "Riff\[$PID:" "$LOG" || true)"
    echo "process: PID $PID ($(printf '%s\n' "$BODY" | wc -l | tr -d ' ') lines)"
fi
c() { printf '%s\n' "$BODY" | grep -c -- "$1" || true; }

nativeNext=$(c "next() → page-native advance")
match=$(c "advance arrived=.* match")
jumps=$(c "jump (row tap)")
ctxStart=$(c "context start (no shown head)")
mismatch=$(c "MISMATCH")
reloads=$(c "] ready$")
ctxSwitch=$(c "context switch → list=")
override=$(c "overriding to head")
addVerified=$(c "queueAddResult VERIFIED")
addFallback=$(c "queueAddResult ok=")
removeOk=$(c "queueRemoveResult ok=true")
removeFail=$(c "queueRemoveResult ok=false")
jump=$(c "skipTo: page-queue jump")
jumpFail=$(c "page didn't jump")
swiftFallback=$(c ".ended → Swift fallback")
jsArmed=$(c ".ended → JS armed via pending URL")
stale=$(c "dropped stale snapshot")

echo
printf '%-44s %s\n' "Next presses advanced page-natively:" "$nativeNext"
printf '%-44s %s / %s / %s / %s\n' "advance audit  match / jump / ctx-start / MISMATCH:" "$match" "$jumps" "$ctxStart" "$mismatch"
printf '%-44s %s\n' "page reloads (ready):" "$reloads"
printf '%-44s %s\n' "context switches (album/playlist starts):" "$ctxSwitch"
printf '%-44s %s\n' "enforcement overrides (overriding to head):" "$override"
printf '%-44s %s verified / %s fallback-retained\n' "Play Next / Add to queue via page:" "$addVerified" "$addFallback"
printf '%-44s %s ok / %s failed\n' "Remove from queue via page:" "$removeOk" "$removeFail"
printf '%-44s %s jumped / %s failed\n' "Row tap (page jump):" "$jump" "$jumpFail"
printf '%-44s swift=%s js-pending=%s\n' "Legacy end-of-track paths used:" "$swiftFallback" "$jsArmed"
printf '%-44s %s\n' "stale snapshots dropped (harmless):" "$stale"
echo

verdict() { printf '  %-8s %s\n' "$1" "$2"; }
echo "Phase D gate:"
[ "$addVerified" -gt 0 ] && [ "$addFallback" -eq 0 ] && verdict PASS "page-owned add verified, no fallback needed" \
    || verdict OPEN "need ≥1 'queueAddResult VERIFIED' and 0 fallbacks — Play Next a song, let it arrive"
[ "$jump" -gt 0 ] && [ "$jumpFail" -eq 0 ] && verdict PASS "row-tap page jump verified" \
    || verdict OPEN "need ≥1 'skipTo: page-queue jump' and 0 failures — tap a row further down Up Next"
[ "$removeOk" -gt 0 ] && [ "$removeFail" -eq 0 ] && verdict PASS "page-owned remove verified" \
    || verdict OPEN "need ≥1 'queueRemoveResult ok=true' — remove a row from Up Next"
[ "$mismatch" -eq 0 ] && [ "$override" -eq 0 ] && verdict PASS "no divergence, no enforcement fired" \
    || verdict OPEN "MISMATCH/override present — inspect: grep -n 'MISMATCH\\|overriding' $LOG"
[ "$swiftFallback" -eq 0 ] && [ "$jsArmed" -eq 0 ] && verdict PASS "legacy end-of-track paths idle" \
    || verdict OPEN "legacy end-of-track path still used — which context? grep '.ended' $LOG"
