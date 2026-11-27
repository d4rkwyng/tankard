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
#   --log DIR     keep each run's stdout/stderr as DIR/run-N.log
#
# A run also fails when the app logs AppKit's "reentrant operation in its
# NSTableView delegate" warning (0.8.4: it is to become an assert).
#
# It reads the real settings and the real brew state, and quits the app
# afterwards; it never installs, upgrades or removes anything. A normal
# launch reads Homebrew's status, as every launch does. Since 0.8 a launch
# may also run the background `brew update` a few seconds in (a fetch of
# Homebrew's metadata, as `brew update` in Terminal), which takes brew's
# lock and moves its FETCH_HEAD. So launch-check sets
# HOMEBREW_NO_AUTO_UPDATE=1 (the app honours it and skips the update)
# unless --allow-brew-update is given. It puts the app's cache folder
# (~/Library/Caches/net.mindtricks.tankard: status.json and the caches next
# to it) back as it found it (0.9.4), so a check leaves no status cache
# for a later launch.
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
# release.sh runs it on the notarized, stapled app (0.9.4; the signed one
# with --skip-notarize), right before making Tankard.zip. In CI that is the
# runner's own Homebrew, read-only, never a user's.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/Tankard.app
SECONDS_UP=15
RUNS=3
LANG_ARGS=()
BUILD=1
ALLOW_UPDATE=0
LOG_DIR=
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --app) APP=${2%/}; BUILD=0; shift ;;
        --seconds) SECONDS_UP=$2; shift ;;
        --runs) RUNS=$2; shift ;;
        --lang) LANG_ARGS=(-AppleLanguages "($2)"); shift ;;
        --allow-brew-update) ALLOW_UPDATE=1 ;;
        --log) LOG_DIR=$2; shift ;;
        -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
        *.app|*.app/) APP=${1%/}; BUILD=0 ;;
        *) echo "launch-check.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
# Whole numbers from 1 up, checked before anything is built, copied or
# launched (0.9.4: `--runs 0` or `--runs abc` made `seq` print nothing, so
# no run happened and the check still exited 0).
for opt in "--runs:$RUNS" "--seconds:$SECONDS_UP"; do
    if ! [[ ${opt#*:} =~ ^[1-9][0-9]{0,5}$ ]]; then
        echo "launch-check.sh: ${opt%%:*} needs a whole number of at least 1, not '${opt#*:}'" >&2
        exit 2
    fi
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
BIN_PHYS=$(cd "$(dirname "$BIN")" && pwd -P)/Tankard
# The process checks, the cache folder's making and the launches
# themselves (see the helper's header).
HELPER="$PWD/Scripts/launch-check-helper.pl"
# Every running Tankard that shares this user's cache folder, "pid path"
# per line: this app (either spelling of its path) and any other build
# (any …/Contents/MacOS/Tankard: all builds read and write the same
# ~/Library/Caches/net.mindtricks.tankard, so one running would write into
# what the check puts back). An exact path compare and a name compare,
# not a prefix: Build1app/…/Tankard-helper is someone else's.
running_tankard() { /usr/bin/perl "$HELPER" running "$BIN_ABS" "$BIN_PHYS"; }
others=$(running_tankard) || { echo "launch-check.sh: could not list the running processes" >&2; exit 1; }
if printf '%s\n' "$others" | awk -v a="$BIN_ABS" -v p="$BIN_PHYS" '{ sub(/^[0-9]+ /, "") } $0 == a || $0 == p { f = 1 } END { exit !f }'; then
    echo "launch-check.sh: $APP is already running; quit it first" >&2
    exit 1
elif [ -n "$others" ]; then
    echo "launch-check.sh: another Tankard is running (pid $(printf '%s\n' "$others" | head -1)), and it shares $HOME/Library/Caches/net.mindtricks.tankard; quit it first" >&2
    exit 1
fi

[ -n "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tankard-launch-check.XXXXXX")
# Absolute (a relative TMPDIR gives a relative path): restore_cache works
# from inside the cache folder, where a relative $WORK/cache is not the copy.
WORK=$(cd "$WORK" && pwd)
TMP_LOG="$WORK/run.log"

# 0.9.4: the app's cache folder (status.json, insights.json, the build-time
# cache) is copied before the first launch and put back as it was on every
# exit. The app still reads the real cache
# and real brew, as a user's launch does; it just leaves nothing behind.
# Before 0.9.4, release.sh's run on the CI runner left a status.json that
# release.yml's later smoke step (Scripts/smoke-launch.sh) then showed.
# The folder itself is never removed or replaced when it was there: it may
# be a symlink (to another volume, say), and that link stays. Its contents
# are copied through it and put back through it, and only into the same
# folder: if the folder (or where its link points) is a different one by
# the end, nothing in it is touched and the copy is kept.
# When there was no folder, the check makes an empty one before the first
# launch (the app writes into it, as it would into one it made itself) and
# removes it on exit, but only that folder: if another one (a link, or a
# folder that is not the one made here) is in its place by then, it is left
# as it is and the check fails.
# Every build of Tankard shares this folder, so no other Tankard may run:
# one found before the copy, or before a launch, stops the check; one found
# at the end (it started meanwhile) leaves the folder as it is (nothing in
# it deleted, the copy kept) and fails the check.
CACHE_DIR="$HOME/Library/Caches/net.mindtricks.tankard"
CACHE_SAVED=0
CACHE_MADE=0     # 1: there was none; the folder at CACHE_ID was made here
CACHE_LINK=      # the link's text, when the folder is a symlink
CACHE_ID=        # device:inode of the folder (through the link)
cache_id() { stat -L -f '%d:%i' "$CACHE_DIR" 2>/dev/null; }
if [ -e "$CACHE_DIR" ] || [ -L "$CACHE_DIR" ]; then
    if [ ! -d "$CACHE_DIR" ]; then
        rm -rf "$WORK"
        echo "launch-check.sh: $CACHE_DIR is not a folder (or its link is broken); nothing was launched" >&2
        exit 1
    fi
    [ -L "$CACHE_DIR" ] && CACHE_LINK=$(readlink "$CACHE_DIR")
    CACHE_ID=$(cache_id) || CACHE_ID=
    mkdir "$WORK/cache"
    ditto "$CACHE_DIR/" "$WORK/cache/" || { rm -rf "$WORK"; echo "launch-check.sh: could not copy $CACHE_DIR; nothing was launched" >&2; exit 1; }
    if [ -z "$CACHE_ID" ] || [ "$(cache_id)" != "$CACHE_ID" ]; then
        rm -rf "$WORK"
        echo "launch-check.sh: $CACHE_DIR changed while it was copied; nothing was launched" >&2
        exit 1
    fi
    CACHE_SAVED=1
else
    # One step (the helper's mkcache): CACHE_ID is the folder made here,
    # taken from its open handle, and nothing that appears at CACHE_DIR
    # meanwhile (a folder, a link) can be taken for it.
    mkdir -p "$(dirname "$CACHE_DIR")" && CACHE_ID=$(/usr/bin/perl "$HELPER" mkcache "$CACHE_DIR") && [ -n "$CACHE_ID" ] || {
        rm -rf "$WORK"
        echo "launch-check.sh: could not make $CACHE_DIR (or it appeared meanwhile); nothing was launched" >&2
        exit 1
    }
    mkdir "$WORK/cache"
    CACHE_MADE=1
fi

# Puts the copy back into the folder it came from. Returns 3, having
# deleted nothing, when that folder is not the one at $CACHE_DIR any more:
# a plain folder that became a link or the other way round, a link that
# now says something else, or another folder (device:inode) in its place.
# A folder that is simply gone is made again (nothing to lose there), or,
# when it was made here (CACHE_MADE), left gone. Any other failure
# (emptying it, or copying back) returns that status. The work happens
# inside the checked folder (`cd`, then relative paths), so a swap after the
# check can't redirect it. A folder made here is emptied the same way and
# then removed with rmdir, which removes only an empty folder.
restore_cache() (
    if [ ! -e "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ] && [ -z "$CACHE_LINK" ]; then
        [ $CACHE_MADE = 1 ] && exit 0
        mkdir "$CACHE_DIR" && cd "$CACHE_DIR" && ditto "$WORK/cache/" ./
        exit
    fi
    if [ -n "$CACHE_LINK" ]; then
        [ -L "$CACHE_DIR" ] && [ "$(readlink "$CACHE_DIR")" = "$CACHE_LINK" ] || exit 3
    else
        [ ! -L "$CACHE_DIR" ] || exit 3
    fi
    [ -d "$CACHE_DIR" ] && cd "$CACHE_DIR" || exit 3
    [ "$(stat -f '%d:%i' .)" = "$CACHE_ID" ] || exit 3
    find . -mindepth 1 -maxdepth 1 -exec rm -rf {} + || exit
    if [ $CACHE_MADE = 1 ]; then
        cd .. && rmdir "$(basename "$CACHE_DIR")"
    else
        ditto "$WORK/cache/" ./
    fi
)

# sup: the helper supervising the current launch (bash's own child; bash
# only ever waits for it, never signals it). The helper alone launches,
# Quits and signals the app, and reaps it only once nothing more will be
# sent to it, so no Quit or signal can reach a reused pid (see its header).
# finish stops a launch by making $WORK/stop: the helper then SIGKILLs and
# reaps the app and exits. If this script dies without finish (SIGKILL),
# the helper sees its parent gone and does the same.
sup=""
finish() {
    local rc=$?
    # Not interruptible: a second Ctrl-C (or a cancelled job's follow-up
    # signal) must not land between emptying the folder and refilling it.
    trap '' INT TERM HUP
    trap - EXIT
    # The launched app must be gone before the cache goes back (an
    # interrupted run can leave it up).
    if [ -n "$sup" ]; then
        : > "$WORK/stop"
        wait "$sup" 2>/dev/null || true
        sup=""
    fi
    # Another Tankard started meanwhile (it would not be refused before
    # the launch) writes into this same folder: nothing is deleted then.
    local others
    others=$(running_tankard) || others="(could not list the running processes)"
    if [ -n "$others" ]; then
        if [ $CACHE_MADE = 1 ]; then
            echo "launch-check.sh: did not remove $CACHE_DIR: another Tankard is running (pid $(printf '%s\n' "$others" | head -1)) and shares it; nothing in it was deleted" >&2
            rm -rf "$WORK"
        else
            echo "launch-check.sh: did not put back $CACHE_DIR: another Tankard is running (pid $(printf '%s\n' "$others" | head -1)) and shares it; nothing in it was deleted. The copy from before the check is in $WORK/cache" >&2
        fi
        exit 1
    fi
    local restored=0
    if [ $CACHE_MADE = 1 ]; then
        restore_cache || restored=$?
        # No copy to keep: the folder was empty when the check made it.
        [ $restored = 0 ] || rm -rf "$WORK"
        if [ $restored = 3 ]; then
            echo "launch-check.sh: did not remove $CACHE_DIR: there was none before the check, and what is there now is not the folder the check made (it was replaced, or is a link); nothing in it was deleted" >&2
            exit 1
        elif [ $restored != 0 ]; then
            echo "launch-check.sh: could not remove $CACHE_DIR, made for the check (there was none before); it may be partly emptied" >&2
            exit 1
        fi
    else
        restore_cache || restored=$?
        if [ $restored = 3 ]; then
            echo "launch-check.sh: did not put back $CACHE_DIR: it is not the folder that was copied (it was replaced, or its link changed); nothing in it was deleted. The copy from before the check is in $WORK/cache" >&2
            exit 1
        elif [ $restored != 0 ]; then
            echo "launch-check.sh: could not put back $CACHE_DIR (it may be empty or partly restored). The copy from before the check is in $WORK/cache" >&2
            exit 1
        fi
    fi
    rm -rf "$WORK"
    exit $rc
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
REENTRANT="reentrant operation in its NSTableView delegate"

failed=0
for run in $(seq 1 "$RUNS"); do
    # Again before every launch: a Tankard started since the first check
    # (while the cache was copied, or during the last run) would share it.
    others=$(running_tankard) || { echo "launch-check.sh: could not list the running processes" >&2; exit 1; }
    if [ -n "$others" ]; then
        echo "launch-check.sh: another Tankard is running (pid $(printf '%s\n' "$others" | head -1)), and it shares $CACHE_DIR; quit it first (run $run/$RUNS was not launched)" >&2
        exit 1
    fi
    before=$(crash_reports)
    rm -f "$WORK/result"
    # A normal launch, window restoration included: that is what users get.
    # Up SECONDS_UP, then Quit the way a user does (a Quit Apple event to
    # this pid only, so macOS doesn't offer to "reopen windows" next time);
    # SIGTERM, then SIGKILL, only if it is still up.
    /usr/bin/perl "$HELPER" supervise "$WORK/result" "$WORK/stop" "$SECONDS_UP" "$TMP_LOG" -- \
        "${ENV_CLEAN[@]}" "$BIN_ABS" ${LANG_ARGS[@]+"${LANG_ARGS[@]}"} &
    sup=$!
    # Returns early on INT/TERM/HUP (their traps exit, and finish stops it).
    sup_rc=0
    wait "$sup" || sup_rc=$?
    sup=""
    result=$(cat "$WORK/result" 2>/dev/null || true)
    launched_pid=$(printf '%s\n' "$result" | sed -n 's/^pid \([0-9][0-9]*\)$/\1/p')
    outcome=$(printf '%s\n' "$result" | sed -n '/^pid /!p' | tail -1)
    alive=0
    stopped_ok=1
    case "$outcome" in
        "exited "*) status="exited ${outcome#exited }" ;;
        "stopped "*)
            alive=1
            set -- $outcome
            # Told to quit, it must exit 0. After the fallback, the signal sent
            # (143 or 137) or 0 is expected; anything else is a failure too.
            case "$2:$3" in
                quit:0|TERM:0|TERM:143|KILL:137) status=running ;;
                quit:*) status="running, then exited $3 when told to quit"; stopped_ok=0 ;;
                TERM:*) status="running, then exited $3 after SIGTERM"; stopped_ok=0 ;;
                *) status="running, then exited $3 after SIGTERM and SIGKILL"; stopped_ok=0 ;;
            esac ;;
        *) status="not supervised to the end (helper exit $sup_rc)" ;;
    esac
    # Crash reports are written a moment after the process dies.
    sleep 3
    new=""
    [ -z "$launched_pid" ] || new=$(reports_for "$launched_pid" "$before" | tr '\n' ' ')
    [ -n "$LOG_DIR" ] && cp "$TMP_LOG" "$LOG_DIR/run-$run.log"
    reentrant=$(grep -c "$REENTRANT" "$TMP_LOG" || true)
    if [ $alive = 1 ] && [ $stopped_ok = 1 ] && [ -z "$new" ] && [ "$reentrant" = 0 ]; then
        echo "launch-check: run $run/$RUNS OK (up ${SECONDS_UP}s, no crash report, no NSTableView reentrancy warning)"
    else
        echo "launch-check: run $run/$RUNS FAILED ($status${new:+, new report: $new}$([ "$reentrant" != 0 ] && echo ", NSTableView reentrancy warning x$reentrant"))" >&2
        failed=1
    fi
done
exit $failed
