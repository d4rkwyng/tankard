#!/bin/bash
# Takes the README/review screenshots with the app's own snapshot hook
# (TANKARD_SNAPSHOT), which works without Screen Recording permission and
# with the screen locked.
#
#   Scripts/screenshots.sh [OUT_DIR] [APP]     (default: dist/screenshots, dist/Tankard.app)
#
# Demo shots use TANKARD_DEMO (fixtures, nothing runs). The "real" shot
# reads this Mac's Homebrew: read-only (`brew info`, git), no `brew update`,
# no upgrades. It also refreshes Tankard's status cache, as any launch would.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-dist/screenshots}
APP=${2:-dist/Tankard.app}
BIN="$APP/Contents/MacOS/Tankard"
mkdir -p "$OUT"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }

shot() { # name delay env...
    local name=$1 delay=$2
    shift 2
    env "$@" TANKARD_SNAPSHOT="$OUT/$name.png" TANKARD_SNAPSHOT_DELAY="$delay" TANKARD_SNAPSHOT_QUIT=1 \
        "$BIN" >/dev/null 2>"$OUT/.$name.log" &
    local pid=$!
    for _ in $(seq 1 $((${delay%.*} + 30))); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "$name: timed out" >&2; fi
    wait "$pid" 2>/dev/null || true
    grep -h "snapshot:" "$OUT/.$name.log" || echo "$name: no snapshot (see $OUT/.$name.log)" >&2
    rm -f "$OUT/.$name.log"
}

shot intelbrew-demo-light 3 TANKARD_DEMO=1 TANKARD_SELECT=python@3.15 TANKARD_APPEARANCE=light
shot intelbrew-demo-dark 3 TANKARD_DEMO=1 TANKARD_SELECT=python@3.15 TANKARD_APPEARANCE=dark
shot upgrade-sheet-demo-light 8.5 TANKARD_DEMO=1 TANKARD_DEMO_UPGRADE=1 TANKARD_APPEARANCE=light
shot upgrade-sheet-demo-dark 8.5 TANKARD_DEMO=1 TANKARD_DEMO_UPGRADE=1 TANKARD_APPEARANCE=dark
shot arm64-demo-light 3 TANKARD_DEMO=arm64 TANKARD_SELECT=google-chrome TANKARD_APPEARANCE=light
if [ "${SKIP_REAL:-0}" != 1 ]; then
    shot real-brew-light 12 TANKARD_SELECT="${REAL_SELECT:-cmake}" TANKARD_APPEARANCE=light
fi
