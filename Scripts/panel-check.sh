#!/bin/bash
# 0.8.5: renders the menu-bar progress panel on each of its pages (demo
# data, TANKARD_DEMO_PANEL) with the snapshot hook, which works with the
# screen locked, and checks that the page's title and its whole button row
# (Stop, Show in Tankard, Retry, Close; the plan's Cancel and Upgrade; the
# notes' Done) lie inside the window, and the window's title. The pages
# report where their title and button rows are (PanelLayoutProbe), since
# SwiftUI's buttons aren't NSViews. Needs a window server; not part of
# `swift test`.
#
#   Scripts/panel-check.sh [BIN] [OUT_DIR]
#
# BIN defaults to the unbundled debug build (.build/debug/TankardApp, built
# first), so no run touches the app's own defaults domain. The PNGs and
# each page's check lines are kept in OUT_DIR (default: a temp dir).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=${1:-}
if [ -z "$BIN" ]; then
    swift build --product TankardApp >/dev/null 2>&1
    BIN=.build/debug/TankardApp
fi
OUT=${2:-$(mktemp -d -t tankard-panel-check)}
mkdir -p "$OUT"

# page delay pace fail expected-title expected-rows...
fails=0
check() {
    local page=$1 delay=$2 pace=$3 fail=$4 title=$5; shift 5
    env TANKARD_DEMO=arm64 TANKARD_DEMO_PACE="$pace" TANKARD_DEMO_PANEL="$page" TANKARD_DEMO_FAIL="$fail" \
        TANKARD_SNAPSHOT="$OUT/$page.png" TANKARD_SNAPSHOT_VIEW=progress TANKARD_SNAPSHOT_DELAY="$delay" \
        TANKARD_SNAPSHOT_QUIT=1 "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>"$OUT/$page.log" &
    local pid=$!
    for _ in $(seq 1 $((delay + 30))); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    grep "panel-check:" "$OUT/$page.log" > "$OUT/$page.txt" || true
    local ok=1
    grep -q "^panel-check: OK$" "$OUT/$page.txt" || ok=0
    grep -q "title \"$title\"" "$OUT/$page.txt" || { echo "$page: window title isn't \"$title\"" >&2; ok=0; }
    for r in "$@"; do
        grep -q "row $r inside" "$OUT/$page.txt" || { echo "$page: row $r missing or outside the window" >&2; ok=0; }
    done
    if [ $ok = 1 ]; then echo "$page: OK ($(head -1 "$OUT/$page.txt" | sed 's/panel-check: //'))"
    else echo "$page: FAIL" >&2; sed 's/^/    /' "$OUT/$page.txt" >&2; fails=$((fails + 1)); fi
}

# The demo's plain upgrades are ada-url and libffi; "failed" fails ada-url.
check plan 5 1 "" "Upgrade Plan" plan.buttons
check running 5 1 "" "Upgrading 2 packages" session.title session.buttons
check finished 9 0.2 "" "Upgrade finished" session.title session.buttons
check failed 9 0.2 ada-url "Upgrade finished with problems" session.title session.buttons
check notes 9 0.2 "" "Post-install notes" notes.buttons

echo "panel-check: PNGs and logs in $OUT"
[ $fails = 0 ] || { echo "panel-check: $fails page(s) failed" >&2; exit 1; }
