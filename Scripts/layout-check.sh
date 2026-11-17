#!/bin/bash
# Checks that the main window's layout doesn't depend on the theme: the
# window frame, the table's position, width, insets and spacing, and every
# visible row and cell must match, the window must not move or resize, and
# the table must not be rebuilt, between Dark, Tankard, Dracula, and live switches (with a
# row selected before the switch and another after). Uses the snapshot
# hook's layout dump (TANKARD_SNAPSHOT_LAYOUT), so it works with the screen
# locked. Needs a window server; not part of `swift test`.
#
#   Scripts/layout-check.sh [APP]        demo data (default dist/Tankard.app)
#   REAL=1 Scripts/layout-check.sh       this Mac's Homebrew, read-only
#                                        (REAL_SELECT / REAL_RESELECT: rows)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-dist/Tankard.app}
BIN="$APP/Contents/MacOS/Tankard"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

if [ "${REAL:-0}" = 1 ]; then
    # (a no-op variable: bash 3 treats an empty array as unset under set -u)
    # TANKARD_REAL is unused by the app: bash 3 treats an empty array as unset under set -u.
    DATA=(TANKARD_REAL=1); SEL=${REAL_SELECT:-libsndfile}; RESEL=${REAL_RESELECT:-abseil}; DELAY=12
else
    DATA=(TANKARD_DEMO=1); SEL=python@3.15; RESEL=curl-impersonate; DELAY=6
fi

run() { # name env...
    local name=$1; shift
    env "${DATA[@]}" "$@" TANKARD_SELECT="$SEL" TANKARD_SNAPSHOT="$OUT/$name.png" TANKARD_SNAPSHOT_DELAY=$DELAY \
        TANKARD_SNAPSHOT_QUIT=1 TANKARD_SNAPSHOT_LAYOUT=1 TANKARD_LOG_FRAMES=1 "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>"$OUT/$name.log" &
    local pid=$!
    for _ in $(seq 1 $((DELAY + 30))); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    # The window frame, the table's x, its clip view (the visible width),
    # and the visible cells must match. Left out: the table's own y and
    # height (SwiftUI measures off-screen rows lazily) and the table's and
    # rows' widths, which can include 15 hidden points under the vertical
    # scroller depending on when SwiftUI last laid the table out, in any
    # theme; the clip view's width is what shows.
    grep '^layout:' "$OUT/$name.log" | grep -v 'layout:  heights' \
        | sed -E -e 's/^layout: table ([0-9.-]+),[0-9.-]+ [0-9.]+x[0-9.]+/layout: table x=\1/' \
                 -e 's/^(layout:  row [0-9]+ [0-9.-]+,[0-9.-]+) [0-9.]+x[0-9.]+/\1/' > "$OUT/$name.txt"
    # Over the whole run: the window never moved or resized, and the table
    # was never rebuilt (a rebuild loses scroll position and column widths).
    local frames tables
    frames=$(grep -c '^frame: \(move\|resize\)' "$OUT/$name.log" || true)
    tables=$(grep '^table:' "$OUT/$name.log" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
    if [ "$frames" != 0 ] || [ "$tables" != 1 ]; then
        echo "MISMATCH: $name: window moved/resized $frames times, $tables table instances" >&2
        grep -E '^(frame|table):' "$OUT/$name.log" >&2
        status=1
    fi
    [ -s "$OUT/$name.txt" ] || { echo "$name: no layout (see log)" >&2; cat "$OUT/$name.log" >&2; exit 1; }
}

status=0
half=$((DELAY / 2))
# Two baselines: a plain Dark launch, and Dark with the same mid-run
# update the switch cases get (a switch to Dark itself, then the reselect).
# The table can be 15 points wider (under the scroller) until its first
# re-layout after launch, whatever the theme, so each case is compared
# with the baseline that had the same updates.
run dark TANKARD_APPEARANCE=dark
run dark-update TANKARD_APPEARANCE=dark TANKARD_SWITCH_APPEARANCE=dark@$half TANKARD_RESELECT=$RESEL@$((half + 2))
run tankard TANKARD_APPEARANCE=tankard
run dracula TANKARD_APPEARANCE=dracula
run dark-to-tankard TANKARD_APPEARANCE=dark TANKARD_SWITCH_APPEARANCE=tankard@$half TANKARD_RESELECT=$RESEL@$((half + 2))
run tankard-to-dark TANKARD_APPEARANCE=tankard TANKARD_SWITCH_APPEARANCE=dark@$half TANKARD_RESELECT=$RESEL@$((half + 2))
run dark-to-dracula TANKARD_APPEARANCE=dark TANKARD_SWITCH_APPEARANCE=dracula@$half TANKARD_RESELECT=$RESEL@$((half + 2))

compare() { # baseline case
    if diff -u "$OUT/$1.txt" "$OUT/$2.txt" >"$OUT/$2.diff"; then
        echo "ok: $2 matches $1 ($(wc -l <"$OUT/$1.txt" | tr -d ' ') layout lines)"
    else
        echo "MISMATCH: $2 vs $1" >&2; cat "$OUT/$2.diff" >&2; status=1
    fi
}
compare dark tankard
compare dark dracula
for n in dark-to-tankard tankard-to-dark dark-to-dracula; do compare dark-update $n; done
exit $status
