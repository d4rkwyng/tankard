#!/bin/bash
# Takes the README/review screenshots with the app's own snapshot hook
# (TANKARD_SNAPSHOT), which works without Screen Recording permission and
# with the screen locked.
#
#   Scripts/screenshots.sh [OUT_DIR] [APP]     (default: dist/screenshots, dist/Tankard.app)
#
# Demo shots use TANKARD_DEMO / TANKARD_DEMO_NOBREW (fixtures, nothing runs,
# no network: Discover's normal mode reads a bundled formulae.brew.sh slice). The "real" shot
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
shot upgrade-sheet-demo-dark 8.5 TANKARD_DEMO=1 TANKARD_DEMO_UPGRADE=1 TANKARD_APPEARANCE=dark
shot arm64-demo-dark 3 TANKARD_DEMO=arm64 TANKARD_SELECT=google-chrome TANKARD_APPEARANCE=dark

# v0.2: the four themes on the main window
for t in dark light system tankard; do
    shot "theme-$t" 3 TANKARD_DEMO=1 TANKARD_SELECT=python@3.15 TANKARD_APPEARANCE=$t
done
# Discover: normal mode (formulae.brew.sh slice) and Intelbrew mode (local taps + brew info)
shot discover-normal 4 TANKARD_DEMO=arm64 TANKARD_DISCOVER=python TANKARD_DISCOVER_SELECT=python@3.14 TANKARD_APPEARANCE=dark
shot discover-intelbrew 5 TANKARD_DEMO=1 TANKARD_DISCOVER=python TANKARD_DISCOVER_SELECT=python@3.14 TANKARD_APPEARANCE=dark
shot discover-intelbrew-tankard 5 TANKARD_DEMO=1 TANKARD_DISCOVER=json TANKARD_DISCOVER_SELECT=json-c TANKARD_APPEARANCE=tankard
# Install from Discover (the shared queue and live-log sheet), and uninstall
shot install-sheet 3.6 TANKARD_DEMO=1 TANKARD_DISCOVER=jq TANKARD_DISCOVER_SELECT=jq TANKARD_DEMO_INSTALL=1 TANKARD_APPEARANCE=dark
shot install-sheet-tankard 7 TANKARD_DEMO=1 TANKARD_DISCOVER=jq TANKARD_DISCOVER_SELECT=jq TANKARD_DEMO_INSTALL=1 TANKARD_APPEARANCE=tankard
shot uninstall-confirm 3 TANKARD_DEMO=1 TANKARD_DEMO_UNINSTALL=vim TANKARD_APPEARANCE=dark
shot uninstall-blocked 3 TANKARD_DEMO=1 TANKARD_DEMO_UNINSTALL=ca-certificates TANKARD_APPEARANCE=dark
# No brew: the welcome screen as on an Intel Mac and on Apple silicon
for t in dark tankard; do
    shot "welcome-intel-$t" 3 TANKARD_DEMO_NOBREW=intel TANKARD_APPEARANCE=$t
    shot "welcome-arm64-$t" 3 TANKARD_DEMO_NOBREW=arm64 TANKARD_APPEARANCE=$t
done

if [ "${SKIP_REAL:-0}" != 1 ]; then
    shot real-brew-light 12 TANKARD_SELECT="${REAL_SELECT:-cmake}" TANKARD_APPEARANCE=light
fi
