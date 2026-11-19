#!/bin/bash
# 0.8.8 (gauntlet 3, B3): renders each Settings tab (General, Upgrades,
# Appearance) in every language with the snapshot hook (demo data, works
# with the screen locked) and checks that the tab's content fits the
# Settings window's width. A row that can't wrap made a tab wider than the
# window, and the window cut it at both edges (French lost the first letters
# of its labels). Each tab reports its laid-out width (SettingsFit); the
# check fails when one is wider than the window. Needs a window server; not
# part of `swift test`. Run it on a test VM, not on a Mac whose Tankard
# settings matter (demo mode keeps its own defaults, but still).
#
#   Scripts/settings-check.sh [APP] [OUT_DIR]
#
# APP defaults to dist/Tankard.app. The PNGs and each run's check lines are
# kept in OUT_DIR (default: a temp dir).
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-dist/Tankard.app}
BIN="$APP/Contents/MacOS/Tankard"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
OUT=${2:-$(mktemp -d -t tankard-settings-check)}
mkdir -p "$OUT"

fails=0
for lang in en de es fr it ja ko pt-BR zh-Hans; do
    for tab in general upgrades appearance; do
        name="$lang-$tab"
        env TANKARD_DEMO=1 TANKARD_SNAPSHOT="$OUT/$name.png" TANKARD_SNAPSHOT_VIEW=settings TANKARD_SETTINGS_TAB="$tab" \
            TANKARD_SETTINGS_CHECK=1 TANKARD_SNAPSHOT_DELAY=4 TANKARD_SNAPSHOT_QUIT=1 \
            "$BIN" -ApplePersistenceIgnoreState YES -AppleLanguages "($lang)" >/dev/null 2>"$OUT/$name.log" &
        pid=$!
        for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        grep "settings-check:" "$OUT/$name.log" > "$OUT/$name.txt" || true
        if grep -q "^settings-check: OK$" "$OUT/$name.txt" && grep -q "tab $tab width" "$OUT/$name.txt"; then
            echo "$name: OK ($(grep "tab $tab width" "$OUT/$name.txt" | sed 's/settings-check: //'))"
        else
            echo "$name: FAIL" >&2
            sed 's/^/    /' "$OUT/$name.txt" >&2
            fails=$((fails + 1))
        fi
    done
done

echo "settings-check: PNGs and logs in $OUT"
[ $fails = 0 ] || { echo "settings-check: $fails tab(s) failed" >&2; exit 1; }
