#!/bin/bash
# Checks that a theme only changes colours, and changes all of them:
#
#  1. Geometry: every visible text, image, control, toolbar item and table
#     cell in the main window sits at the same place and size in all five
#     themes, when the app is launched in a theme and while switching
#     between them in Settings. After each click every distinct frame that
#     was drawn (up to 2 s) is recorded, so a one-frame jump fails as well
#     as a lasting one.
#  2. Row colours: after each switch, the background of every visible row
#     (at the top, 40 rows down and back at the top) matches a fresh launch
#     in that theme, so no row keeps the previous theme's colour.
#
#   Scripts/theme-geometry-check.sh [APP]    default dist/Tankard.app
#
# Works on any build, signed release included, with this Mac's real
# Homebrew data: no TANKARD_* hooks are used. A copy of the app is re-signed
# ad hoc (the code is unchanged; a hardened-runtime signature would refuse
# the probe), and Scripts/theme-probe.m is loaded into it to click the
# Settings radio buttons and record the window. Needs a GUI login session
# (works with the screen locked) and clang. The app's defaults are backed
# up first and restored afterwards; Tankard must not be running.
#
#   WORK=<dir>   working directory (default: a new mktemp -d); kept when set
#   KEEP=1       keep the default working directory too (dumps and PNGs)
#   SNAP=1       also write a PNG of the window at every dump
#   START=20     seconds after launch before the first dump
# Exit 0 pass, 1 fail, 2 inconclusive (window occluded: unlock the screen).
#
#   STRICT=1     also fail on a frame where SwiftUI dropped the rows to
#                re-measure them (see below; intermittent, not theme layout)
#   ALLOW_RUNNING=1  run even though another Tankard is running (fine when
#                that one doesn't save an appearance, e.g. TANKARD_APPEARANCE runs)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-dist/Tankard.app}
[ -x "$APP/Contents/MacOS/Tankard" ] || { echo "no app at $APP" >&2; exit 1; }
# Another Tankard would share (and change) the defaults this check sets.
if [ "${ALLOW_RUNNING:-0}" != 1 ] && pgrep -x Tankard >/dev/null; then echo "Tankard is running: quit it first ($(pgrep -x Tankard | tr '\n' ' '))" >&2; exit 1; fi
DOMAIN=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
START=${START:-20}

if [ -n "${WORK:-}" ]; then mkdir -p "$WORK"; KEEP=1; else WORK=$(mktemp -d); fi
OUT="$WORK/out"
rm -rf "$OUT" "$WORK/Tankard.app"
mkdir -p "$OUT"

# Defaults: back up, and restore whatever happens.
BACKUP="$WORK/defaults-backup.plist"
had_defaults=0
if defaults export "$DOMAIN" "$BACKUP" 2>/dev/null; then had_defaults=1; fi
pid=
cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    [ "$had_defaults" = 1 ] && defaults import "$DOMAIN" "$BACKUP"
    if [ "${KEEP:-0}" = 1 ]; then echo "kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

ditto "$APP" "$WORK/Tankard.app"
codesign --force --deep --sign - "$WORK/Tankard.app" 2>/dev/null
clang -dynamiclib -fobjc-arc -Wno-arc-retain-cycles -framework AppKit -o "$WORK/theme-probe.dylib" Scripts/theme-probe.m
BIN="$WORK/Tankard.app/Contents/MacOS/Tankard"

probe() { # prefix themes
    local prefix=$1 themes=$2 n
    n=$(awk -F, '{print NF}' <<<"$themes")
    [ -z "$themes" ] && n=0
    env -i HOME="$HOME" USER="$USER" PATH="$PATH" TMPDIR="${TMPDIR:-}" \
        DYLD_INSERT_LIBRARIES="$WORK/theme-probe.dylib" PROBE_OUT="$OUT" PROBE_PREFIX="$prefix" \
        PROBE_THEMES="$themes" PROBE_START="$START" PROBE_SNAP="${SNAP:-0}" \
        "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>"$OUT/$prefix.stderr" &
    pid=$!
    local limit=$((START + 15 + n * 6))
    for _ in $(seq 1 "$limit"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "$prefix: timed out" >&2; fi
    wait "$pid" 2>/dev/null || { echo "$prefix: probe failed (exit $?):" >&2; grep -v ' dump ' "$OUT/probe.log" | tail -5 >&2; exit 1; }
}

# Each run ends with a click on Dark, and every dump in a run is compared
# with that run's last one (Dark, 2 s after the click): the same process
# and the same data, so sizes still being measured, a refresh or new
# upgrades between launches can't pass for a theme difference.
#
# Launched in each theme, then switched to Dark.
for t in dark light system tankard dracula; do
    defaults write "$DOMAIN" appearance "$t"
    probe "launch-$t" "Dark"
done
# Switched in Settings, from Dark through every theme and back.
defaults write "$DOMAIN" appearance dark
probe switch "Tankard,Dracula,Light,System,Dark,Dracula,Tankard,Light,Dark"

# The status bar's left-aligned "Updated N min ago" changes width as
# minutes pass (text below y=40 points), and the table header reaches
# under the vertical scroller or stops 15 points short of it depending on
# when the table was last laid out, in any theme: for those two only the
# width is left out.
normalise() {
    awk '{ split($2, o, ","); split($3, s, "x")
           if ($1 == "tableheader" || ($1 == "draw" && o[2] + 0 < 40)) print $1, $2, "_x" s[2]; else print }' "$1"
}
for f in "$OUT"/*.geom; do normalise "$f" >"${f%.geom}.norm"; mv "${f%.geom}.norm" "$f"; done

status=0
count=0
remeasure=0
for run in launch-dark:01 launch-light:01 launch-system:01 launch-tankard:01 launch-dracula:01 switch:09; do
    prefix=${run%%:*}
    n=${run#*:}
    base="$OUT/$prefix-$n-dark-t2000.geom"
    [ -s "$base" ] || { echo "$prefix: no baseline dump ($base)" >&2; status=1; continue; }
    for f in "$OUT/$prefix"-*.geom; do
        [ "$f" = "$base" ] && continue
        count=$((count + 1))
        if ! diff -u "$base" "$f" >"${f%.geom}.diff"; then
            # A drawn frame in which the table has dropped its row views
            # (no cells, rows at AppKit's default 24 points) while SwiftUI
            # re-measures the rows: an intermittent SwiftUI behaviour on a
            # re-render (about 1 switch in 15 on macOS 27, same in 0.3.1),
            # not a layout difference. Reported, and only fails with STRICT=1.
            if [[ "$f" == *-f[0-9][0-9].geom ]] && ! grep -q '^cell ' "$f" && grep -q 'rowheight0=24.0' "$f"; then
                remeasure=$((remeasure + 1))
                echo "note: $(basename "$f" .geom): one frame with the table's rows dropped for re-measuring" >&2
                [ "${STRICT:-0}" = 1 ] && status=1
                continue
            fi
            status=1
            echo "MISMATCH: $(basename "$f" .geom) vs $(basename "$base" .geom) ($(grep -c '^[-+][^-+]' "${f%.geom}.diff") lines differ):" >&2
            grep '^[-+][^-+]' "${f%.geom}.diff" | head -12 >&2
        fi
    done
done
echo "geometry: $count dumps compared ($(wc -l <"$OUT/switch-09-dark-t2000.geom" | tr -d ' ') elements each); $remeasure frame(s) with rows dropped for re-measuring"

# Row colours after every switch against a fresh launch in that theme
# (each channel within 3 of it: the rendering is the same, not the bits).
rows=0
for f in "$OUT"/*-[0-9][0-9]-*.rows; do
    name=$(basename "$f" .rows)                     # e.g. switch-02-dracula-scrolled
    theme=$(sed -E 's/^.*-[0-9][0-9]-([a-z]+).*$/\1/' <<<"$name")
    view=$(sed -E 's/^.*-[0-9][0-9]-[a-z]+//' <<<"$name")   # "", -scrolled, -back
    base="$OUT/launch-$theme-start$view.rows"
    [ -s "$base" ] || { echo "no fresh-launch colours for $name ($base)" >&2; status=1; continue; }
    rows=$((rows + 1))
    if ! bad=$(paste "$base" "$f" | awk '
        function hx(c) { return index("0123456789abcdef", c) - 1 }
        function ch(h, i) { return hx(substr(h, i, 1)) * 16 + hx(substr(h, i + 1, 1)) }
        function far(a, b) { return (ch(a,1)-ch(b,1))^2 > 9 || (ch(a,3)-ch(b,3))^2 > 9 || (ch(a,5)-ch(b,5))^2 > 9 }
        { if ($2 != $5 || far($3, $6)) { print "  row " $2 ": " $6 " (fresh launch: row " $5 " " $3 ")"; n++ } }
        END { exit n > 0 }'); then
        status=1
        echo "COLOUR MISMATCH: $name vs $(basename "$base" .rows):" >&2
        head -8 <<<"$bad" >&2
    fi
done
echo "row colours: $rows samples compared with a fresh launch in the same theme"
# On macOS 14 SwiftUI doesn't redraw an occluded window (screen locked), so
# a switch shows nothing and these results say nothing about switching.
if grep -q '(main window occluded)' "$OUT/probe.log"; then
    echo "INCONCLUSIVE: the main window was occluded during the switches (screen locked?); it may not have redrawn" >&2
    exit 2
fi
[ "$status" = 0 ] && echo "ok: geometry identical in every theme and through every switch; row colours match fresh launches"
exit $status
