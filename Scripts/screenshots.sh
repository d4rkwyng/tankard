#!/bin/bash
# Takes the README/review screenshots with the app's own snapshot hook
# (TANKARD_SNAPSHOT), which works without Screen Recording permission and
# with the screen locked.
#
#   Scripts/screenshots.sh [OUT_DIR] [APP]     (default: dist/screenshots, dist/Tankard.app)
#   SET=v0.3 Scripts/screenshots.sh [OUT_DIR]  only the v0.3 shots
#   SET=v0.4a Scripts/screenshots.sh [OUT_DIR] only the v0.4 part A shots
#   SET=v0.4b Scripts/screenshots.sh [OUT_DIR] only the 0.4 vulnerability/notes/size shots
#   SET=v0.4 Scripts/screenshots.sh [OUT_DIR]  both 0.4 sets
#   SET=v0.5 Scripts/screenshots.sh [OUT_DIR]  the 0.5 auto-update shots
#   SET=v0.6a Scripts/screenshots.sh [OUT_DIR] the 0.6 part A shots (deprecated, Health, History, autoremove)
#   SET=v0.6b Scripts/screenshots.sh [OUT_DIR] skip version, Brewfile export/check/plan
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
        "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>"$OUT/.$name.log" &
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

v03() {
    # v0.3: menu bar, compile warnings, cleanup, replace with bottle, Discover's
    # bottle chip, App Management, Settings, About
    shot menubar-dark 3 TANKARD_DEMO=1 TANKARD_SNAPSHOT_VIEW=menubar TANKARD_APPEARANCE=dark
    shot menubar-tankard 3 TANKARD_DEMO=1 TANKARD_SNAPSHOT_VIEW=menubar TANKARD_APPEARANCE=tankard
    shot menubar-arm64-light 3 TANKARD_DEMO=arm64 TANKARD_SNAPSHOT_VIEW=menubar TANKARD_APPEARANCE=light
    shot upgrade-plan-compile-warning-dark 3 TANKARD_DEMO=1 TANKARD_DEMO_UPGRADE=plan TANKARD_APPEARANCE=dark
    shot upgrade-plan-compile-warning-tankard 3 TANKARD_DEMO=1 TANKARD_DEMO_UPGRADE=plan TANKARD_APPEARANCE=tankard
    shot upgrades-filter-compile-warning-dark 3 TANKARD_DEMO=1 TANKARD_FILTER=upgrades TANKARD_SELECT=ruby TANKARD_APPEARANCE=dark
    shot cleanup-intelbrew-dark 3.5 TANKARD_DEMO=1 TANKARD_DEMO_CLEANUP=1 TANKARD_APPEARANCE=dark
    shot cleanup-arm64-light 3.5 TANKARD_DEMO=arm64 TANKARD_DEMO_CLEANUP=1 TANKARD_APPEARANCE=light
    shot cleanup-running-dark 6 TANKARD_DEMO=1 TANKARD_DEMO_CLEANUP=1 TANKARD_APPEARANCE=dark TANKARD_DEMO_CLEANUP_RUN=1
    shot replace-bottle-detail-dark 3 TANKARD_DEMO=1 TANKARD_SELECT=vim TANKARD_APPEARANCE=dark
    shot bottle-available-filter-dark 3 TANKARD_DEMO=1 TANKARD_FILTER=bottle TANKARD_SELECT=vim TANKARD_APPEARANCE=dark
    shot bottle-available-filter-tankard 3 TANKARD_DEMO=1 TANKARD_FILTER=bottle TANKARD_SELECT=vim TANKARD_APPEARANCE=tankard
    shot replace-bottle-running-dark 5 TANKARD_DEMO=1 TANKARD_SELECT=vim TANKARD_DEMO_REPLACE=1 TANKARD_APPEARANCE=dark
    shot discover-intelbrew-chip-dark 5 TANKARD_DEMO=1 TANKARD_DISCOVER=ffmpeg TANKARD_DISCOVER_SELECT=ffmpeg TANKARD_APPEARANCE=dark
    shot discover-intelbrew-unbottled-dark 5 TANKARD_DEMO=1 TANKARD_DISCOVER=node TANKARD_DISCOVER_ALL=1 TANKARD_DISCOVER_SELECT=node-red TANKARD_APPEARANCE=dark
    shot discover-intelbrew-unbottled-tankard 5 TANKARD_DEMO=1 TANKARD_DISCOVER=node TANKARD_DISCOVER_ALL=1 TANKARD_DISCOVER_SELECT=node-red TANKARD_APPEARANCE=tankard
    shot discover-install-compiles-confirm-dark 5 TANKARD_DEMO=1 TANKARD_DISCOVER=node TANKARD_DISCOVER_ALL=1 TANKARD_DISCOVER_SELECT=node-red TANKARD_DEMO_INSTALL_CONFIRM=1 TANKARD_APPEARANCE=dark
    shot discover-normal-chip-dark 4 TANKARD_DEMO=arm64 TANKARD_DISCOVER=python TANKARD_DISCOVER_SELECT=python@3.14 TANKARD_APPEARANCE=dark
    shot app-management-dark 3 TANKARD_DEMO=arm64 TANKARD_DEMO_APPMGMT=1 TANKARD_APPEARANCE=dark
    shot app-management-tankard 3 TANKARD_DEMO=arm64 TANKARD_DEMO_APPMGMT=1 TANKARD_APPEARANCE=tankard
    shot app-management-blocked-dark 9 TANKARD_DEMO=arm64 TANKARD_DEMO_APPMGMT=fail TANKARD_DEMO_UPGRADE=1 TANKARD_DEMO_PACE=0.15 TANKARD_APPEARANCE=dark
    shot settings-general-dark 3 TANKARD_DEMO=1 TANKARD_SNAPSHOT_VIEW=settings TANKARD_APPEARANCE=dark
    shot about-dark 3 TANKARD_DEMO=1 TANKARD_SNAPSHOT_VIEW=about TANKARD_APPEARANCE=dark
    shot about-light 3 TANKARD_DEMO=1 TANKARD_SNAPSHOT_VIEW=about TANKARD_APPEARANCE=light
}
v04a() {
    # v0.4 part A: pins, Requested only, dependency links and tree, Services,
    # the Homebrew menu's sheets. Dark and Tankard for each.
    for t in dark tankard; do
        shot pinned-detail-$t 3 TANKARD_DEMO=1 TANKARD_DEMO_PINNED=sqlite,xz TANKARD_SELECT=sqlite TANKARD_APPEARANCE=$t
        shot pinned-filter-$t 3 TANKARD_DEMO=1 TANKARD_DEMO_PINNED=sqlite,xz TANKARD_FILTER=pinned TANKARD_SELECT=xz TANKARD_APPEARANCE=$t
        shot requested-only-$t 3 TANKARD_DEMO=1 TANKARD_FILTER=leaves TANKARD_SELECT=vim TANKARD_APPEARANCE=$t
        shot dependency-tree-$t 3 TANKARD_DEMO=1 TANKARD_SELECT=python@3.15 TANKARD_TREE=all TANKARD_SNAPSHOT_SIZE=1040x760 TANKARD_APPEARANCE=$t
        shot services-$t 3.5 TANKARD_DEMO=1 TANKARD_TAB=services TANKARD_SERVICE_SELECT=postgresql@18 TANKARD_APPEARANCE=$t
        shot services-root-$t 3.5 TANKARD_DEMO=1 TANKARD_TAB=services TANKARD_SERVICE_SELECT=unbound TANKARD_APPEARANCE=$t
        shot revert-sheet-$t 3 TANKARD_DEMO=1 TANKARD_DEMO_MANAGE=revert TANKARD_DEMO_TYPED=revert TANKARD_SNAPSHOT_SIZE=1040x760 TANKARD_APPEARANCE=$t
        shot uninstall-sheet-$t 3 TANKARD_DEMO=arm64 TANKARD_DEMO_MANAGE=uninstall TANKARD_APPEARANCE=$t
    done
}

v04b() {
    # v0.4 part B: vulnerabilities, caveats, sizes, self-updating apps (Dark and Tankard)
    for t in dark tankard; do
        shot "vulnerable-filter-$t" 4 TANKARD_DEMO=1 TANKARD_FILTER=vulnerable TANKARD_SELECT=openssl@4 TANKARD_APPEARANCE=$t
        shot "notes-filter-$t" 4 TANKARD_DEMO=1 TANKARD_FILTER=notes TANKARD_SELECT=python@3.15 TANKARD_APPEARANCE=$t
        shot "post-install-notes-$t" 9 TANKARD_DEMO=1 TANKARD_DEMO_NOTES=1 TANKARD_DEMO_PACE=0.05 TANKARD_APPEARANCE=$t
        shot "sizes-arm64-$t" 4 TANKARD_DEMO=arm64 TANKARD_SELECT=visual-studio-code TANKARD_APPEARANCE=$t
        shot "self-updating-arm64-$t" 4 TANKARD_DEMO=arm64 TANKARD_SELF_UPDATING=1 TANKARD_FILTER=upgrades TANKARD_SELECT=tailscale-app TANKARD_APPEARANCE=$t
        shot "settings-upgrades-$t" 3 TANKARD_DEMO=1 TANKARD_SNAPSHOT_VIEW=settings-upgrades TANKARD_APPEARANCE=$t
        shot "menubar-vulnerability-notice-$t" 4 TANKARD_DEMO=1 TANKARD_DEMO_VULN_NOTICE=1 TANKARD_SNAPSHOT_VIEW=menubar TANKARD_APPEARANCE=$t
    done
}

v05() {
    # v0.5: automatic updates. Settings → Upgrades, the log, the menu-bar line
    # (a real run through the demo's fake brew; nothing is installed).
    for t in dark tankard; do
        shot "autoupdate-settings-$t" 3 TANKARD_DEMO=1 TANKARD_DEMO_AUTOUPDATE=1 TANKARD_SNAPSHOT_VIEW=settings-autoupdate TANKARD_APPEARANCE=$t
        shot "autoupdate-log-intelbrew-$t" 6 TANKARD_DEMO=1 TANKARD_DEMO_AUTOUPDATE=run TANKARD_DEMO_PACE=0.02 TANKARD_SNAPSHOT_VIEW=autoupdate-log TANKARD_APPEARANCE=$t
        shot "autoupdate-log-arm64-$t" 6 TANKARD_DEMO=arm64 TANKARD_DEMO_AUTOUPDATE=run TANKARD_DEMO_PACE=0.02 TANKARD_SNAPSHOT_VIEW=autoupdate-log TANKARD_APPEARANCE=$t
        shot "autoupdate-menubar-$t" 6 TANKARD_DEMO=1 TANKARD_DEMO_AUTOUPDATE=run TANKARD_DEMO_PACE=0.02 TANKARD_SNAPSHOT_VIEW=menubar TANKARD_APPEARANCE=$t
    done
}

v06a() {
    for t in dark tankard; do
        shot deprecated-badge-$t 3 TANKARD_DEMO=1 TANKARD_SELECT=json-c TANKARD_APPEARANCE=$t
        shot deprecated-filter-$t 3 TANKARD_DEMO=1 TANKARD_FILTER=deprecated TANKARD_SELECT=json-c TANKARD_APPEARANCE=$t
        shot health-$t 4 TANKARD_DEMO=1 TANKARD_DEMO_SHEET=health TANKARD_APPEARANCE=$t
        shot history-$t 3 TANKARD_DEMO=1 TANKARD_DEMO_SHEET=history TANKARD_APPEARANCE=$t
        shot autoremove-confirm-$t 3.5 TANKARD_DEMO=1 TANKARD_DEMO_SHEET=autoremove TANKARD_APPEARANCE=$t
    done
}

v06b() {
    # v0.6 part B: Skip This Version (taller window, so the button shows),
    # the Brewfile export summary, check result and restore plan (fixtures).
    for t in dark tankard; do
        shot "skip-version-detail-$t" 3 TANKARD_DEMO=1 TANKARD_FILTER=upgrades TANKARD_SELECT=sqlite TANKARD_SNAPSHOT_SIZE=1040x860 TANKARD_APPEARANCE=$t
        shot "brewfile-export-summary-$t" 5 TANKARD_DEMO=arm64 TANKARD_DEMO_BREWFILE=export TANKARD_APPEARANCE=$t
        shot "brewfile-check-result-$t" 5 TANKARD_DEMO=arm64 TANKARD_DEMO_BREWFILE=check TANKARD_APPEARANCE=$t
        shot "brewfile-restore-plan-$t" 7 TANKARD_DEMO=arm64 TANKARD_DEMO_BREWFILE=plan TANKARD_SNAPSHOT_SIZE=1040x760 TANKARD_APPEARANCE=$t
    done
}

if [ "${SET:-all}" = v0.6b ]; then v06b; exit 0; fi
if [ "${SET:-all}" = v0.3 ]; then v03; exit 0; fi
if [ "${SET:-all}" = v0.6a ]; then v06a; exit 0; fi
if [ "${SET:-all}" = v0.5 ]; then v05; exit 0; fi
if [ "${SET:-all}" = v0.4a ]; then v04a; exit 0; fi
if [ "${SET:-all}" = v0.4b ]; then v04b; exit 0; fi
if [ "${SET:-all}" = v0.4 ]; then v04a; v04b; exit 0; fi

shot intelbrew-demo-light 3 TANKARD_DEMO=1 TANKARD_SELECT=python@3.15 TANKARD_APPEARANCE=light
shot intelbrew-demo-dark 3 TANKARD_DEMO=1 TANKARD_SELECT=python@3.15 TANKARD_APPEARANCE=dark
shot upgrade-sheet-demo-dark 8.5 TANKARD_DEMO=1 TANKARD_DEMO_UPGRADE=1 TANKARD_APPEARANCE=dark
shot arm64-demo-dark 3 TANKARD_DEMO=arm64 TANKARD_SELECT=google-chrome TANKARD_APPEARANCE=dark

# The five themes on the main window
for t in dark light system tankard dracula; do
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

v03
v04a
v04b
v05

if [ "${SKIP_REAL:-0}" != 1 ]; then
    shot real-brew-light 12 TANKARD_SELECT="${REAL_SELECT:-cmake}" TANKARD_APPEARANCE=light
fi
