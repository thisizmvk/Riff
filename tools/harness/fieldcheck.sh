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
# OR grade the audit journal from a diagnostics export (Settings →
# Export diagnostics) — no live capture needed; the app journals every
# audit line in memory and the export writes it out:
#   ./tools/harness/fieldcheck.sh ~/Downloads/riff-diagnostics-*/bridge-journal.log
#
# By default only the LAST app process in the file is graded (a relaunch
# starts a new PID); --all grades everything. A non-empty file with no
# 'Riff[PID:' token (a journal/export, which is single-process by
# construction) is graded whole.
set -euo pipefail
LOG="${1:-$HOME/Downloads/riff-bridge.log}"
ALL="${2:-}"
[ -f "$LOG" ] || { echo "no log at $LOG"; exit 2; }

if [ "$ALL" = "--all" ]; then
    BODY="$(cat "$LOG")"
else
    PID="$(grep -o 'Riff\[[0-9]*:' "$LOG" | tail -1 | tr -dc '0-9' || true)"
    if [ -z "$PID" ]; then
        # Journal/export files carry no PID token; grade them as-is.
        # An EMPTY file is still an error — likely a wrong-style capture.
        [ -s "$LOG" ] || { echo "no 'Riff[PID:' lines in $LOG — capture with --style compact (see header) or rerun with --all" >&2; exit 2; }
        BODY="$(cat "$LOG")"
        echo "no 'Riff[PID:' token — grading whole file as a journal/export ($(wc -l < "$LOG" | tr -d ' ') lines)"
    else
        BODY="$(grep "Riff\[$PID:" "$LOG" || true)"
        echo "process: PID $PID ($(printf '%s\n' "$BODY" | wc -l | tr -d ' ') lines)"
    fi
fi
c() { printf '%s\n' "$BODY" | grep -c -- "$1" || true; }

nativeNext=$(c "next() → page-native advance")
match=$(c "advance arrived=.* match")
jumps=$(c "jump (row tap)")
ctxStart=$(c "context start (no shown head)")
mismatch=$(c "MISMATCH")
# Reloads: prefer the audit token PlayerBridge journals once per
# document ready ("page ready → bridge armed" — present in journal
# exports AND live captures from current builds). Fall back to the raw
# per-event ready line for legacy captures: Release logs a bare
# "… ready"; Debug echoes the payload too ("… ready [\"event\":
# \"ready\"]") — match both, or a Debug-build capture always grades
# "0 reloads". Never SUM the two counts: a live capture from a current
# build carries both lines for every reload.
reloads=$(c "page ready → bridge armed")
if [ "$reloads" -eq 0 ]; then
    reloads=$(c '] ready\( \[\|$\)')
fi
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
addDisabled=$(c "via=store-dispatch-disabled")
[ "$addVerified" -gt 0 ] && [ "$addFallback" -eq 0 ] && verdict PASS "page-owned add verified, no fallback needed" \
    || { [ "$addDisabled" -gt 0 ] && verdict OPEN "page store dispatch is disabled (desyncs the player); Play Next uses Riff's own path until a page-native add exists — see queueApi below" \
    || verdict OPEN "need ≥1 'queueAddResult VERIFIED' and 0 fallbacks — Play Next a song, let it arrive"; }
[ "$jump" -gt 0 ] && [ "$jumpFail" -eq 0 ] && verdict PASS "row-tap page jump verified" \
    || verdict OPEN "need ≥1 'skipTo: page-queue jump' and 0 failures — tap a row further down Up Next"
[ "$removeOk" -gt 0 ] && [ "$removeFail" -eq 0 ] && verdict PASS "page-owned remove verified" \
    || verdict OPEN "need ≥1 'queueRemoveResult ok=true' — remove a row from Up Next"
[ "$mismatch" -eq 0 ] && [ "$override" -eq 0 ] && verdict PASS "no divergence, no enforcement fired" \
    || verdict OPEN "MISMATCH/override present — inspect: grep -n 'MISMATCH\\|overriding' $LOG"
[ "$swiftFallback" -eq 0 ] && [ "$jsArmed" -eq 0 ] && verdict PASS "legacy end-of-track paths idle" \
    || verdict OPEN "legacy end-of-track path still used — which context? grep '.ended' $LOG"

api="$(printf '%s\n' "$BODY" | grep -o 'queueApi: .*' | head -1 || true)"
if [ -n "$api" ]; then
    echo
    echo "page queue API surface (one-shot probe):"
    printf '%s\n' "$api" | cut -c1-900
fi
