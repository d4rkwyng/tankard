#!/bin/bash
# 0.8.3: the self-upgrade end to end, on this Mac's real brew and
# /Applications, with two builds of this tree:
#
#   Scripts/e2e-selfupdate.sh --old OLD.app --new NEW.app --out DIR [--phases ABC] [--appdir DIR]
#
# OLD and NEW: release builds (Scripts/bundle-app.sh) whose TankardVersion
# and CFBundleShortVersionString differ, NEW the newer (semver: 0.8.3 and
# 0.8.4-e2e.1). A throwaway local tap, tankard-e2e-self/tap (never
# d4rkwyng/tap), serves a cask `tankard` from file:// zips of them.
#
#   A  fixed build -> newer: install OLD with the cask, run it as a script
#      (TANKARD_E2E_SELFUPDATE=1: relaunch on, counted by the guard) through
#      Check for Tankard Updates, Upgrade with Homebrew, the quiet mode, a
#      sheet left open, then the alert's Relaunch. Pass: the old pid gone,
#      exactly one Tankard afterwards, running NEW.
#   B  same-build double launch: `open` then `open -n` the installed app.
#      Pass: the second activates the first and quits; one pid.
#   C  a stale copy with a sheet open (0.8.2's Relaunch opened the new copy
#      first): OLD runs with a sheet up, the shell upgrades the cask to NEW
#      and runs `open -n`. Pass: the new copy asks the old one to quit (and
#      alerts if the sheet refuses it); once the old one is gone, exactly
#      one Tankard, running NEW.
#
# --phases: run only these (default ABC). Without A, B installs NEW first
# (quarantine removed, as install_old does). Scripts/rc-selfupdate-signed.sh
# uses it when OLD is a release whose relaunch passes the script
# environment on (before 0.8.4), which phase A can't judge.
# --appdir DIR: brew installs the cask's app there (brew --appdir) instead
# of /Applications, e.g. a scratch folder, so nothing in /Applications is
# touched while a Gatekeeper prompt might be pending. The checks below then
# mean DIR/Tankard.app.
#
# Each phase: a 0.25 s process timeline, `log stream` of Tankard's
# subsystem, the app's stderr, and no new Tankard .ips in
# ~/Library/Logs/DiagnosticReports. The real settings domain
# (net.mindtricks.tankard) is backed up first and must be byte-identical at
# the end; if not, it is restored from the backup and the run FAILS
# (isolation/real-defaults). Refuses to start if Tankard runs, if
# /Applications/Tankard.app (or --appdir's) exists, or if the tap or a
# tankard cask exists. Cleans up the cask, the tap, the app and its processes.
set -uo pipefail
cd "$(dirname "$0")/.."
# step_result, step_logged, relaunch_logged, ran_tankard_code, no_instance_yield
# (0.8.4; `Scripts/e2e-selfupdate-checks.sh --self-test` checks them).
source Scripts/e2e-selfupdate-checks.sh

OLD= NEW= OUT= PHASES=ABC APPDIR=/Applications
while [ $# -gt 0 ]; do
    case "$1" in
        --old) OLD=${2%/}; shift ;;
        --new) NEW=${2%/}; shift ;;
        --out) OUT=$2; shift ;;
        --phases) PHASES=$2; shift ;;
        --appdir) APPDIR=${2%/}; shift ;;
        -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
        *) echo "e2e-selfupdate.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
[ -d "$OLD" ] && [ -d "$NEW" ] && [ -n "$OUT" ] || { echo "usage: --old OLD.app --new NEW.app --out DIR [--phases ABC] [--appdir DIR]" >&2; exit 2; }
[[ $PHASES =~ ^[ABC]+$ ]] || { echo "e2e-selfupdate.sh: --phases takes letters from ABC, got '$PHASES'" >&2; exit 2; }
want() { [[ $PHASES == *$1* ]]; }
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
OLD=$(cd "$OLD" && pwd); NEW=$(cd "$NEW" && pwd)
VOLD=$(plutil -extract CFBundleShortVersionString raw "$OLD/Contents/Info.plist")
VNEW=$(plutil -extract CFBundleShortVersionString raw "$NEW/Contents/Info.plist")
TAP=tankard-e2e-self/tap
CASK=$TAP/tankard
mkdir -p "$APPDIR" && APPDIR=$(cd "$APPDIR" && pwd) || { echo "e2e-selfupdate.sh: can't use --appdir $APPDIR" >&2; exit 2; }
APP=$APPDIR/Tankard.app
# Every install and upgrade of the cask goes to APPDIR (brew remembers it
# for the uninstall, and for the old app's own upgrade in phase A).
CASKARGS=(--appdir="$APPDIR")
APP_RE=$(printf '%s' "$APP" | sed 's/[][\.*^$+?(){}|]/\\&/g')
BREW=$(command -v brew)
qbrew() { HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" "$@"; }
# No `brew ... | grep -q` under pipefail: grep quits at the first match,
# brew can get SIGPIPE, and the pipeline then fails (141) on a match.
has_tap() { grep -qx "$TAP" <<<"$(qbrew tap 2>/dev/null)"; }
has_cask() { grep -qx tankard <<<"$(qbrew list --cask 2>/dev/null)"; }
SUITE=net.mindtricks.tankard.e2e.$$
RESULTS=()
record() { RESULTS+=("$1"); echo "==> $1" | tee -a "$OUT/summary.txt"; }
now() { date +%H:%M:%S; }
# Only the installed app's processes: other worktrees' builds (dist/, demo
# and e2e runs of parallel work) are never counted or touched.
pids() { pgrep -f "^$APP_RE/Contents/MacOS/Tankard" | tr '\n' ' ' | sed 's/ $//'; }

# MARK: preconditions (never touch what isn't ours)
[ -z "$(pids)" ] || { echo "e2e-selfupdate.sh: Tankard is running (pids $(pids)); quit it first" >&2; exit 3; }
[ ! -e "$APP" ] || { echo "e2e-selfupdate.sh: $APP exists; this run installs its own and would remove it" >&2; exit 3; }
has_tap && { echo "e2e-selfupdate.sh: tap $TAP already exists" >&2; exit 3; }
has_cask && { echo "e2e-selfupdate.sh: a tankard cask is installed" >&2; exit 3; }
# The machine-wide e2e lock (Scripts/e2e.sh's): one run using brew and the app at a time.
LOCK=/tmp/net.mindtricks.tankard.e2e.lock
until mkdir "$LOCK" 2>/dev/null; do
    h=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$h" ] && ! kill -0 "$h" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    echo "e2e-selfupdate.sh: waiting for the e2e lock (pid ${h:-?})" >&2; sleep 5
done
echo $$ > "$LOCK/pid"; echo "$(pwd) selfupdate" > "$LOCK/where"
MARK="$OUT/.start"; touch "$MARK"
: > "$OUT/summary.txt"

# 0.8.4: the real settings. Phases B and C start the installed app with no
# script (the real identity), and AppKit writes keys (NSWindow Frame ...)
# into net.mindtricks.tankard that no TANKARD_E2E_SUITE catches; a
# notarized build can't be re-signed with its own identifier the way
# e2e.sh isolates it. So the domain is fingerprinted (md5, as e2e.sh) and
# exported now; at the end it is restored from that copy if it changed, and
# the run fails (isolation/real-defaults).
REAL_DOMAIN=net.mindtricks.tankard
REAL_PLIST=~/Library/Preferences/$REAL_DOMAIN.plist
REAL_BACKUP="$OUT/real-defaults-backup.plist"
real_fingerprint() { if [ -f "$REAL_PLIST" ]; then /sbin/md5 -q "$REAL_PLIST"; else echo absent; fi; }
real_xml() { defaults export "$REAL_DOMAIN" - 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null; }
REAL_MD5=$(real_fingerprint)
rm -f "$REAL_BACKUP"
if [ "$REAL_MD5" != absent ]; then
    defaults export "$REAL_DOMAIN" "$REAL_BACKUP" && [ -s "$REAL_BACKUP" ] \
        || { echo "e2e-selfupdate.sh: couldn't back up $REAL_DOMAIN; not starting" >&2; rm -rf "$LOCK"; exit 1; }
fi
echo "real settings: $REAL_DOMAIN md5 $REAL_MD5$([ -f "$REAL_BACKUP" ] && echo ", backup $REAL_BACKUP")" | tee -a "$OUT/summary.txt"
# Another Tankard (not this run's) may write the domain meanwhile; noted.
others() { pgrep -f 'Tankard.app/Contents/MacOS/Tankard' | grep -vxF -f <(pids | tr ' ' '\n'; echo x) | tr '\n' ' ' | sed 's/ $//'; }
OTHER_TANKARD=$(others)
REAL_CHECKED=0
# real_check: once, after this run's apps are gone. Restores and fails
# when the domain changed.
# 0.8.3 as OLD: its window (phase C's sheet; A's and B's runs) saves its
# frame into the real domain, which 0.8.3 can't avoid. While OLD is older
# than 0.8.4, keys matching exactly `NSWindow Frame *` are labelled "known
# 0.8.3-as-old artifact" and don't fail the run; every other changed key
# does. Gated on OLD's version, so the exception disappears on its own once
# OLD is 0.8.4 or later. The domain is restored in full either way.
REAL_IGNORE_FRAMES=0
version_lt "$VOLD" 0.8.4 && REAL_IGNORE_FRAMES=1
real_check() {
    [ $REAL_CHECKED = 1 ] && return 0
    REAL_CHECKED=1
    sleep 2   # cfprefsd flushes a quitting app's writes shortly after
    local after restored diffs verdict=FAIL
    after=$(real_fingerprint)
    if [ "$after" = "$REAL_MD5" ]; then
        record "isolation/real-defaults: PASS ($REAL_DOMAIN unchanged, md5 $REAL_MD5)"
        return 0
    fi
    # The full key diff, from the backup and the domain as it is now.
    local now="$OUT/real-defaults-after.plist"
    # Binary, like the backup: an XML plist keeps whole seconds only, so a
    # date key (lastBrewUpdate) would look changed against the binary backup.
    defaults export "$REAL_DOMAIN" "$now" 2>/dev/null
    [ -s "$now" ] || printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict/></plist>' > "$now"
    diffs=$(real_defaults_diff "$([ -f "$REAL_BACKUP" ] && echo "$REAL_BACKUP")" "$now" $REAL_IGNORE_FRAMES) && verdict=PASS
    # Always restored in full. `defaults import` merges, so delete first:
    # the domain is then exactly the copy.
    defaults delete "$REAL_DOMAIN" >/dev/null 2>&1
    if [ "$REAL_MD5" = absent ]; then
        rm -f "$REAL_PLIST"
        [ "$(real_fingerprint)" = absent ] && restored="removed again (it didn't exist before)" || { restored="NOT removed"; verdict=FAIL; }
    elif defaults import "$REAL_DOMAIN" "$REAL_BACKUP" \
        && cmp -s <(plutil -convert xml1 -o - "$REAL_BACKUP") <(real_xml); then
        restored="restored from $REAL_BACKUP (content equal)"
    else
        restored="RESTORE FAILED: defaults import $REAL_DOMAIN $REAL_BACKUP by hand"; verdict=FAIL
    fi
    local o; o=${OTHER_TANKARD:-$(others)}
    local why="md5 $REAL_MD5 -> $after; $restored"
    [ $verdict = PASS ] && why="only NSWindow Frame keys changed (OLD $VOLD < 0.8.4: known 0.8.3-as-old artifact); $why"
    record "isolation/real-defaults: $verdict ($REAL_DOMAIN changed: $why${o:+; another Tankard ran: pids $o})"
    if [ -n "$diffs" ]; then echo "$diffs" | sed 's/^/      key /' | tee -a "$OUT/summary.txt"
    else echo "      (no key differs: the file was rewritten)" | tee -a "$OUT/summary.txt"; fi
    [ $verdict = PASS ]
}
stop_apps() {
    for p in $(pids); do kill "$p" 2>/dev/null; done
    sleep 1
    for p in $(pids); do kill -9 "$p" 2>/dev/null; done
}

STARTED=()
cleanup() {
    local rc=$?
    echo "==> cleanup"
    stop_apps
    [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" 2>/dev/null
    [ -n "${LOGSTREAM:-}" ] && kill "$LOGSTREAM" 2>/dev/null
    has_cask && qbrew uninstall --cask "$CASK" >> "$OUT/brew.log" 2>&1
    has_tap && qbrew untap "$TAP" >> "$OUT/brew.log" 2>&1
    [ -e "$APP" ] && echo "cleanup: $APP still present" >&2
    defaults delete "$SUITE" >/dev/null 2>&1; rm -f ~/Library/Preferences/"$SUITE".plist
    # The relaunched copies' script folders (AppManagement.relaunchEnvironment):
    # their app is gone by now; the phase's verdict is already recorded.
    rm -rf "$OUT"/[ABC]/relaunched
    rm -rf "$LOCK"
    echo "after cleanup: pids=[$(pids)] app=$([ -e "$APP" ] && echo present || echo absent) tap=$(qbrew tap | grep -cx "$TAP")" | tee -a "$OUT/summary.txt"
    # An interrupted run: the real settings are still checked and restored.
    if [ $REAL_CHECKED = 0 ] && ! real_check; then [ $rc = 0 ] && exit 1; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# MARK: the tap and its cask
qbrew tap-new --no-git "$TAP" > "$OUT/brew.log" 2>&1 || { echo "tap-new failed" >&2; exit 1; }
TAPDIR=$(qbrew --repository "$TAP")
mkdir -p "$TAPDIR/Casks" "$OUT/zips"
for v in old new; do
    src=$OLD; [ $v = new ] && src=$NEW
    ditto -c -k --keepParent "$src" "$OUT/zips/tankard-$v.zip"
done
write_cask() { # old|new
    local v=$VOLD z="$OUT/zips/tankard-old.zip"
    [ "$1" = new ] && { v=$VNEW; z="$OUT/zips/tankard-new.zip"; }
    cat > "$TAPDIR/Casks/tankard.rb" <<RUBY
cask "tankard" do
  version "$v"
  sha256 "$(shasum -a 256 "$z" | cut -d' ' -f1)"
  url "file://$z"
  name "Tankard"
  desc "Tankard self-update e2e (throwaway)"
  homepage "https://github.com/d4rkwyng/tankard"
  app "Tankard.app"
end
RUBY
}
FEED="$OUT/feed.json"
printf '{"tag_name":"v%s","body":"e2e build","html_url":"https://github.com/d4rkwyng/tankard/releases/tag/v%s","draft":false,"prerelease":false}\n' "$VNEW" "$VNEW" > "$FEED"

install_old() {
    write_cask old
    qbrew install --cask "${CASKARGS[@]}" "$CASK" >> "$OUT/brew.log" 2>&1 || { echo "install failed" >&2; return 1; }
    # An ad-hoc signed test build: no quarantine, as a notarized release wouldn't need.
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null
    [ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VOLD" ]
}
# --phases without A: B needs NEW installed (A would have left it there).
install_new() {
    write_cask new
    qbrew install --cask "${CASKARGS[@]}" "$CASK" >> "$OUT/brew.log" 2>&1 || { echo "install failed" >&2; return 1; }
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null
    [ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VNEW" ]
}

start_watch() { # dir
    ( while true; do
        ts=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
        ps -axo pid=,ppid=,lstart=,command= | grep -E '[T]ankard.app/Contents/MacOS/Tankard|[k]ill -0|[o]pen -n' | sed "s/^/$ts /"
        echo "$ts --"
        sleep 0.25
      done ) > "$1/timeline.txt" 2>&1 &
    SAMPLER=$!
    /usr/bin/log stream --style compact --predicate 'subsystem == "net.mindtricks.tankard" OR (process == "logger") OR (process == "ReportCrash")' > "$1/logstream.txt" 2>&1 &
    LOGSTREAM=$!
    sleep 1
}
stop_watch() { kill "$SAMPLER" "$LOGSTREAM" 2>/dev/null; SAMPLER= LOGSTREAM=; }
wait_for() { # seconds, condition...
    local t=$1; shift
    local i=0
    while ! "$@" && [ $i -lt $((t * 4)) ]; do sleep 0.25; i=$((i + 1)); done
    "$@"
}
one_new_running() {
    local p; p=$(pids)
    [ -n "$p" ] && [ "$(echo "$p" | wc -w | tr -d ' ')" = 1 ] && [ "$p" != "${1:-}" ] \
        && [ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VNEW" ]
}
# Crash reports since the start for the installed app (not other builds).
ips_new() { find ~/Library/Logs/DiagnosticReports -name 'Tankard*.ips' -newer "$MARK" -exec grep -lF "$APP" {} + 2>/dev/null | wc -l | tr -d ' '; }
quit_all() { for p in $(pids); do kill "$p" 2>/dev/null; done; wait_for 10 test -z "$(pids)" >/dev/null; }

script_env() { # dir
    echo TANKARD_E2E=1 TANKARD_E2E_SELFUPDATE=1 TANKARD_E2E_SELF_TAP=$TAP TANKARD_E2E_SUITE=$SUITE \
        TANKARD_SCRIPT=$1/steps.txt TANKARD_SCRIPT_OUT=$1 TANKARD_E2E_STATE=$1/state TANKARD_UPDATE_FEED=$FEED
}

# MARK: A  fixed build -> newer, sheet open at Relaunch
D=$OUT/A
if ! want A; then
    echo "$(now) A: skipped (--phases $PHASES)"
elif mkdir -p "$D" && echo "$(now) A: install $VOLD" | tee "$D/events.txt" && install_old; then
    write_cask new   # the tap now offers the newer build
    cat > "$D/steps.txt" <<STEPS
expect-ready
check-updates $VNEW brew
upgrade-self $VNEW
expect-quiet 5
open-sheet history
relaunch
STEPS
    start_watch "$D"
    env $(script_env "$D") "$APP/Contents/MacOS/Tankard" -ApplePersistenceIgnoreState YES > "$D/app.log" 2>&1 &
    OLDPID=$!
    echo "$(now) A: old pid $OLDPID" | tee -a "$D/events.txt"
    i=0; while kill -0 $OLDPID 2>/dev/null && [ $i -lt 900 ]; do sleep 1; i=$((i + 1)); done
    # 0: NSApp.terminate (the relaunch); a script that ran on exits 1.
    wait $OLDPID; OLDRC=$?
    echo "$(now) A: old pid $OLDPID exited, status $OLDRC" | tee -a "$D/events.txt"
    wait_for 20 one_new_running "$OLDPID"
    sleep 3   # a late second instance would show up here
    NEWPID=$(pids)
    echo "$(now) A: after: pids=[$NEWPID] bundle=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist") ips_new=$(ips_new)" | tee -a "$D/events.txt"
    [ -n "$NEWPID" ] && ps -o pid=,lstart=,command= -p "$NEWPID" | tee -a "$D/events.txt"
    stop_watch
    # 0.8.4: a pid count and the bundle's version aren't evidence on their
    # own (rc2 passed with a new pid that never logged a line). Also
    # required: steps 1-5 passed in the old copy (from its app.log: the
    # relaunched copy recreates results.jsonl), its relaunch helper and
    # terminate lines, no copy yielding to another, and a line from the new
    # pid itself.
    WHY=()
    for s in "1 expect-ready" "2 check-updates $VNEW brew" "3 upgrade-self $VNEW" "4 expect-quiet 5" "5 open-sheet history"; do
        r=$(step_logged "$D/app.log" "${s%% *}" "${s#* }") || WHY+=("step ${s%% *} ${s#* }: $r")
    done
    r=$(relaunch_logged "$D/logstream.txt" "$OLDPID") || WHY+=("relaunch: $r")
    r=$(no_instance_yield "$D/logstream.txt") || WHY+=("$r")
    NEWRAN=$(ran_tankard_code "$D/logstream.txt" "$NEWPID") || WHY+=("new pid: $NEWRAN")
    # 0.8.4: the new copy inherits no TANKARD_* variable but an idle e2e
    # identity, its output in $D/relaunched (its summary.json can take a
    # moment: the store starts first).
    wait_for 30 test -f "$D/relaunched/summary.json" >/dev/null
    r=$(relaunched_idle "$D") || WHY+=("relaunched copy: $r")
    [ "$OLDRC" = 0 ] || WHY+=("old pid exit status $OLDRC")
    one_new_running "$OLDPID" || WHY+=("not exactly one new Tankard running $VNEW: pids=[$(pids)]")
    [ "$(ips_new)" = 0 ] || WHY+=("ips_new=$(ips_new)")
    printf 'A evidence: %s\n' "${WHY[@]:-all present}" >> "$D/events.txt"
    if [ ${#WHY[@]} = 0 ]; then
        record "A fixed->newer relaunch: PASS (old $OLDPID: steps 1-5 passed, helper + terminate logged, gone; one Tankard $NEWPID running $VNEW, idle e2e copy, its log: ${NEWRAN#ok: }; no yield, no .ips)"
    else
        record "A fixed->newer relaunch: FAIL ($(IFS=';'; echo "${WHY[*]}"); see $D)"
    fi
else
    record "A: FAIL (install of $VOLD)"
fi

# MARK: B  same-build double launch
D=$OUT/B
if ! want B; then
    echo "$(now) B: skipped (--phases $PHASES)"
elif ! want A && ! install_new; then
    record "B: FAIL (install of $VNEW)"
else
mkdir -p "$D"
quit_all
start_watch "$D"
open "$APP"; wait_for 15 test -n "$(pids)"
FIRST=$(pids); sleep 4
echo "$(now) B: first pid $FIRST; open -n" | tee "$D/events.txt"
open -n "$APP"; sleep 6
echo "$(now) B: after: pids=[$(pids)]" | tee -a "$D/events.txt"
stop_watch
if [ "$(pids)" = "$FIRST" ] && grep -q "yield(to: $FIRST)" "$D/logstream.txt" && [ "$(ips_new)" = 0 ]; then
    record "B same-build double launch: PASS (second launch yielded to $FIRST and quit)"
else
    record "B same-build double launch: FAIL (pids=[$(pids)], first $FIRST; see $D)"
fi
quit_all
fi

# MARK: C  stale copy with a sheet open, 0.8.2-style open-first
D=$OUT/C
if ! want C; then
    echo "$(now) C: skipped (--phases $PHASES)"
elif mkdir -p "$D" && { ! has_cask || qbrew uninstall --cask "$CASK" >> "$OUT/brew.log" 2>&1; } \
    && echo "$(now) C: install $VOLD" | tee "$D/events.txt" && install_old; then
    cat > "$D/steps.txt" <<STEPS
expect-ready
open-sheet history
sleep 30
close-sheets
sleep 10
STEPS
    start_watch "$D"
    env $(script_env "$D") "$APP/Contents/MacOS/Tankard" -ApplePersistenceIgnoreState YES > "$D/app.log" 2>&1 &
    OLDPID=$!
    # 0.8.4: wait for step 2's result line (the screenshot alone was taken
    # as "sheet up", and the wait timing out went on regardless: rc2's C
    # said "has its sheet up" with no results.jsonl at all).
    # Still waiting while step 2 is "missing" or "missing (no FILE)" (before
    # results.jsonl exists; rc2 matrix: comparing with exactly "missing"
    # ended the 180 s wait at once) and the old pid runs.
    sheet_done() {
        case "$(step_result "$D/results.jsonl" 2 "open-sheet history")" in
            missing*) ! kill -0 $OLDPID 2>/dev/null ;;
            *) true ;;
        esac
    }
    wait_for 180 sheet_done >/dev/null
    SHEET=$(step_result "$D/results.jsonl" 2 "open-sheet history")
    if [ "$SHEET" != ok ] || ! kill -0 $OLDPID 2>/dev/null; then
        echo "$(now) C: no sheet up in old pid $OLDPID (step 2: $SHEET; $(kill -0 $OLDPID 2>/dev/null && echo running || echo exited))" | tee -a "$D/events.txt"
        stop_watch
        record "C stale copy with sheet: FAIL (the sheet never came up: step 2 $SHEET; see $D)"
        quit_all
    else
    echo "$(now) C: old pid $OLDPID has its sheet up (step 2: ok); brew upgrade to $VNEW (no quit), then open -n" | tee -a "$D/events.txt"
    write_cask new
    HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 qbrew upgrade --cask "${CASKARGS[@]}" "$CASK" >> "$OUT/brew.log" 2>&1
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null
    open -n "$APP"
    echo "$(now) C: opened new; pids=[$(pids)]" | tee -a "$D/events.txt"
    i=0; while kill -0 $OLDPID 2>/dev/null && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done
    echo "$(now) C: old pid $OLDPID exited ($(kill -0 $OLDPID 2>/dev/null && echo NOT || echo yes))" | tee -a "$D/events.txt"
    sleep 3
    echo "$(now) C: after: pids=[$(pids)] ips_new=$(ips_new)" | tee -a "$D/events.txt"
    stop_watch
    ALERT=$(grep -c "alert" "$D/logstream.txt" || true)
    if ! kill -0 $OLDPID 2>/dev/null && one_new_running "$OLDPID" && grep -q "replaceStale" "$D/logstream.txt" && [ "$(ips_new)" = 0 ]; then
        record "C stale copy with sheet: PASS (new copy asked $OLDPID to quit; alert lines: $ALERT; one Tankard $(pids) running $VNEW)"
    else
        record "C stale copy with sheet: FAIL (pids=[$(pids)]; see $D)"
    fi
    fi
else
    record "C: FAIL (install of $VOLD)"
fi

stop_apps
real_check
echo
printf '%s\n' "${RESULTS[@]}"
grep -q FAIL <<<"$(printf '%s\n' "${RESULTS[@]}")" && exit 1
exit 0
