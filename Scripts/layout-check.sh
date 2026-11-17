#!/bin/bash
# Checks that the main window's layout doesn't depend on the theme: the
# table's position, insets and spacing, and every visible cell's origin
# must match between Dark, Tankard, Dracula, and live switches (with a
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
        TANKARD_SNAPSHOT_QUIT=1 TANKARD_SNAPSHOT_LAYOUT=1 "$BIN" >/dev/null 2>"$OUT/$name.log" &
    local pid=$!
    for _ in $(seq 1 $((DELAY + 30))); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    # Origins only: widths may differ by the scroller (the table can run
    # under an overlay scroller), and the table's own y and height change
    # as SwiftUI measures rows lazily; visible rows and cells must not move.
    grep '^layout:' "$OUT/$name.log" | grep -v 'layout: window' \
        | sed -E -e 's/^layout: table ([0-9.-]+),[0-9.-]+ [0-9.]+x[0-9.]+/layout: table x=\1/' \
                 -e 's/ ([0-9.-]+),([0-9.-]+) [0-9.]+x[0-9.]+/ \1,\2/g' > "$OUT/$name.txt"
    [ -s "$OUT/$name.txt" ] || { echo "$name: no layout (see log)" >&2; cat "$OUT/$name.log" >&2; exit 1; }
}

half=$((DELAY / 2))
run dark TANKARD_APPEARANCE=dark
run tankard TANKARD_APPEARANCE=tankard
run dark-to-tankard TANKARD_APPEARANCE=dark TANKARD_SWITCH_APPEARANCE=tankard@$half TANKARD_RESELECT=$RESEL@$((half + 2))
run tankard-to-dark TANKARD_APPEARANCE=tankard TANKARD_SWITCH_APPEARANCE=dark@$half TANKARD_RESELECT=$RESEL@$((half + 2))
run dracula TANKARD_APPEARANCE=dracula
run dark-to-dracula TANKARD_APPEARANCE=dark TANKARD_SWITCH_APPEARANCE=dracula@$half TANKARD_RESELECT=$RESEL@$((half + 2))

status=0
for n in tankard dark-to-tankard tankard-to-dark dracula dark-to-dracula; do
    if diff -u "$OUT/dark.txt" "$OUT/$n.txt" >"$OUT/$n.diff"; then
        echo "ok: $n matches dark ($(wc -l <"$OUT/dark.txt" | tr -d ' ') layout lines)"
    else
        echo "MISMATCH: $n vs dark" >&2; cat "$OUT/$n.diff" >&2; status=1
    fi
done
exit $status
