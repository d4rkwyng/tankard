#!/bin/bash
# Real-launch smoke test: builds Tankard.app and launches it the way a user
# does (no TANKARD_DEMO, no TANKARD_SNAPSHOT), then checks it is still
# running after a while and left no new crash report. Run it before every
# release (release.sh does). Needs a logged-in GUI session.
#
#   Scripts/launch-check.sh [--no-build] [--app PATH] [--seconds N] [--runs N] [PATH.app]
#
#   PATH.app      an existing app to check, e.g. the notarized CI artifact
#                 (same as --app PATH; implies --no-build)
#   --no-build    use the existing app (default: build with bundle-app.sh)
#   --app PATH    the app to launch (default: dist/Tankard.app); no build
#   --seconds N   how long it must stay up (default: 15)
#   --runs N      launch it N times in a row (default: 3)
#   --lang L      launch it in language L (-AppleLanguages "(L)"), e.g. de
#   --allow-brew-update
#                 let the app run its background `brew update` (0.8+); by
#                 default the app is launched with HOMEBREW_NO_AUTO_UPDATE=1
#
# It reads the real settings and the real brew state, and quits the app
# afterwards; it never installs, upgrades or removes anything. A normal
# launch reads Homebrew's status, as every launch does. Since 0.8 a launch
# may also run the background `brew update` a few seconds in (a fetch of
# Homebrew's metadata, as `brew update` in Terminal), which takes brew's
# lock and moves its FETCH_HEAD. So launch-check sets
# HOMEBREW_NO_AUTO_UPDATE=1 (the app honours it and skips the update)
# unless --allow-brew-update is given.
#
# Why it exists: 0.3.0 shipped a launch crash (App.body re-evaluated in a
# loop until the stack overflowed) that every demo and snapshot run hid.
# It also hid from local builds: it needed the release toolchain's
# @Observable (Swift 6.1, which notifies on equal writes) and showed up on
# about half of the launches of the Developer ID-signed app. So check the
# artifact you ship, not only a local build:
#
#   Scripts/launch-check.sh --runs 5 path/to/downloaded/Tankard.app
#
# release.sh runs it on the signed app before notarizing.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/Tankard.app
SECONDS_UP=15
RUNS=3
LANG_ARGS=()
BUILD=1
ALLOW_UPDATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --app) APP=${2%/}; BUILD=0; shift ;;
        --seconds) SECONDS_UP=$2; shift ;;
        --runs) RUNS=$2; shift ;;
        --lang) LANG_ARGS=(-AppleLanguages "($2)"); shift ;;
        --allow-brew-update) ALLOW_UPDATE=1 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *.app|*.app/) APP=${1%/}; BUILD=0 ;;
        *) echo "launch-check.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

[ $BUILD = 1 ] && Scripts/bundle-app.sh --out "$(dirname "$APP")"
BIN="$APP/Contents/MacOS/Tankard"
[ -x "$BIN" ] || { echo "launch-check.sh: no app at $APP" >&2; exit 1; }

REPORTS=~/Library/Logs/DiagnosticReports
crash_reports() { ls "$REPORTS" 2>/dev/null | grep -E '^Tankard[-_.]' || true; }
# New Tankard reports written for this PID (other Tankard runs on the same
# Mac, e.g. screenshot scripts, don't count).
reports_for() {
    local pid=$1 f
    for f in $(comm -13 <(echo "$2") <(crash_reports)); do
        grep -qE "\"pid\" *: *$pid,|^Process: .*\[$pid\]" "$REPORTS/$f" 2>/dev/null && echo "$REPORTS/$f"
    done
    return 0
}

# The demo/snapshot switches hid the 0.3.0 crash: launch without any of them.
ENV_CLEAN=(env)
for v in $(env | sed -n 's/^\(TANKARD_[A-Z_]*\)=.*/\1/p'); do ENV_CLEAN+=(-u "$v"); done
# No background `brew update` unless asked (see the header).
[ $ALLOW_UPDATE = 1 ] || ENV_CLEAN+=(HOMEBREW_NO_AUTO_UPDATE=1)

BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/Tankard
if pgrep -f "^$BIN_ABS" >/dev/null; then
    echo "launch-check.sh: $APP is already running; quit it first" >&2
    exit 1
fi

failed=0
for run in $(seq 1 "$RUNS"); do
    before=$(crash_reports)
    # A normal launch, window restoration included: that is what users get.
    "${ENV_CLEAN[@]}" "$BIN_ABS" ${LANG_ARGS[@]+"${LANG_ARGS[@]}"} >/dev/null 2>&1 &
    pid=$!
    alive=1
    for _ in $(seq 1 "$SECONDS_UP"); do
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then alive=0; break; fi
    done
    status=running
    if [ $alive = 1 ]; then
        # Quit it the way a user does (a Quit Apple event to this pid only), so
        # macOS doesn't offer to "reopen windows" next time; kill as a fallback.
        osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (a) a.terminate; ''" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    else
        wait "$pid" && status="exited 0" || status="exited $?"
    fi
    # Crash reports are written a moment after the process dies.
    sleep 3
    new=$(reports_for "$pid" "$before" | tr '\n' ' ')
    if [ $alive = 1 ] && [ -z "$new" ]; then
        echo "launch-check: run $run/$RUNS OK (up ${SECONDS_UP}s, no crash report)"
    else
        echo "launch-check: run $run/$RUNS FAILED ($status${new:+, new report: $new})" >&2
        failed=1
    fi
done
exit $failed
