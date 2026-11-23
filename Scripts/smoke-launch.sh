#!/bin/bash
# Clean-machine launch smoke test for the zip that ships (0.9.2), after
# First Light's (d4rkwyng/first-light#22: its 1.0.0/1.0.1 launch crash,
# a Bundle.module that only found the build machine's .build path) and
# Owlink's (d4rkwyng/owlink b74f55a).
#
#   Scripts/smoke-launch.sh [--seconds N] PATH/Tankard.zip
#
#   --seconds N   how long the app must stay up (default: 10, minimum 10)
#
# Unzips the zip (ditto, like Finder) into a fresh temp folder and checks
# that copy of Tankard.app, never the build tree's:
#   1. Layout and signature: Contents/MacOS/Tankard, the password helper
#      (Contents/Helpers/TankardPassword.app), AppIcon.icns, both SwiftPM
#      resource bundles in Contents/Resources (tankard_TankardApp.bundle:
#      the mug and mark images; tankard_TankardAppModel.bundle: the demo
#      data), Localizable.strings for every CFBundleLocalizations language
#      in the app and in the helper, nothing at the .app root, no *.bundle
#      outside Contents/Resources, and `codesign --verify --deep --strict`;
#      for a Team ID (Developer ID) build also `stapler validate` and
#      `spctl -a -t exec`.
#   2. Hides the build machine's fallbacks while the checks below run. A
#      SwiftPM Bundle.module accessor falls back to the absolute .build
#      path it was compiled with, and on the machine (or CI runner) that
#      built the app that path exists, so it would mask a zip without its
#      resource bundles. The script reads the checkout roots embedded in
#      the executables (absolute …/Sources/<Target>/….swift paths) plus its
#      own checkout, and renames each root's .build, Resources,
#      Sources/TankardApp/Resources and Sources/TankardAppModel/Resources,
#      and any other absolute *.bundle path compiled in under one of those
#      roots, to
#      "<path>.smoke-hidden". A trap renames them back on every exit
#      (pass, failure, Ctrl-C); if one can't be restored the script says
#      what to `mv` and exits non-zero. Don't run it while a build or test
#      run is using that checkout.
#   3. Resource bundles load: the unzipped app's two resource bundles are
#      opened with NSBundle and the files the app reads are looked up the
#      way the app does (AppResources.bundle, Demo.resources), with the
#      fallbacks hidden.
#   4. A real launch of the unzipped executable with TANKARD_DEMO=1 (demo
#      data, never Homebrew) and no window restoration, inside a sandbox
#      profile that denies any read, write or exec under /opt/homebrew,
#      /usr/local/Homebrew, /usr/local/Cellar, /usr/local/Caskroom and
#      /usr/local/bin/brew (self-tested first with a denied probe file in
#      the temp folder, plus each of those paths that exists here), with
#      HOMEBREW_* unset but HOMEBREW_NO_AUTO_UPDATE=1 and no brew on PATH.
#      A Developer ID build ignores every TANKARD_* switch (TestHooks), so
#      on the release runner the app launches as a user's would; the
#      sandbox makes it see no Homebrew there, and it can't start brew
#      either way. It must stay up N seconds, then quit
#      with exit code 0 within 8 s of a Quit (terminate) event.
#   5. No new crash report (.ips or .crash, new = a file name not in a
#      listing taken before the launch; ReportCrash touches old reports'
#      mtimes and moves some into Retired/) anywhere under
#      ~/Library/Logs/DiagnosticReports or /Library/Logs/DiagnosticReports
#      (Retired/ included) whose name starts with Tankard, TankardPassword,
#      or any executable or bundle name in the zip. It waits up to 15 s for
#      ReportCrash after the app exits, on every path. Any new one fails;
#      the pid inside each says whether it was this launch or a helper or
#      other run.
# Exit 0 = SMOKE PASS. Needs a logged-in GUI session (CI runners have one).
set -euo pipefail

SECONDS_UP=10
ZIP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_UP=${2:?--seconds needs a value}; shift ;;
        -h|--help) sed -n '2,53p' "$0"; exit 0 ;;
        -*) echo "smoke-launch.sh: unknown option $1" >&2; exit 2 ;;
        *) ZIP=$1 ;;
    esac
    shift
done
[ -n "$ZIP" ] && [ -f "$ZIP" ] || { echo "usage: $0 [--seconds N] PATH/Tankard.zip" >&2; exit 2; }
case "$SECONDS_UP" in ''|*[!0-9]*) echo "smoke-launch.sh: --seconds must be a whole number" >&2; exit 2 ;; esac
[ "$SECONDS_UP" -ge 10 ] || { echo "smoke-launch.sh: --seconds must be at least 10" >&2; exit 2; }
ZIP=$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")
HERE=$(cd "$(dirname "$0")/.." && pwd)

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
# Runs a command with a time limit (perl's alarm: no coreutils `timeout`
# on a stock Mac).
with_alarm() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

TMP=""
PID=""
HIDDEN=()
RESTORE_FAILED=0
restore() {
    local d stuck=()
    for d in ${HIDDEN[@]+"${HIDDEN[@]}"}; do
        if [ -e "$d.smoke-hidden" ] && [ ! -e "$d" ] && mv "$d.smoke-hidden" "$d"; then
            echo "restored $d"
        elif [ -e "$d" ] && [ ! -e "$d.smoke-hidden" ]; then
            :   # already back
        else
            stuck+=("$d"); RESTORE_FAILED=1
            echo "SMOKE ERROR: could not restore $d; fix by hand: mv '$d.smoke-hidden' '$d'" >&2
        fi
    done
    HIDDEN=(${stuck[@]+"${stuck[@]}"})
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if [ -n "$PID" ]; then kill -9 "$PID" 2>/dev/null || true; fi
    restore
    if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
    if [ $RESTORE_FAILED = 1 ]; then
        echo "SMOKE ERROR: build-machine path(s) left renamed (see above)" >&2
        exit 1
    fi
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# 0. A fresh copy of what ships.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tankard-smoke.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
mkdir "$TMP/unzipped"
ditto -x -k "$ZIP" "$TMP/unzipped"
APP="$TMP/unzipped/Tankard.app"
[ -d "$APP" ] || { ls -la "$TMP/unzipped" >&2; fail "$ZIP does not unpack to Tankard.app"; }
echo "unzipped $(basename "$ZIP") to $APP"
RES="$APP/Contents/Resources"
HELPER_APP="$APP/Contents/Helpers/TankardPassword.app"

# 1. Layout and signature.
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist does not parse"
EXE_NAME=$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist")
[ "$EXE_NAME" = Tankard ] || fail "CFBundleExecutable is '$EXE_NAME', expected Tankard"
EXE="$APP/Contents/MacOS/$EXE_NAME"
[ -x "$EXE" ] || fail "no executable at Contents/MacOS/$EXE_NAME"
plutil -lint "$HELPER_APP/Contents/Info.plist" >/dev/null 2>&1 || fail "no or unreadable Contents/Helpers/TankardPassword.app/Contents/Info.plist"
HELPER_NAME=$(plutil -extract CFBundleExecutable raw -o - "$HELPER_APP/Contents/Info.plist")
HELPER_EXE="$HELPER_APP/Contents/MacOS/$HELPER_NAME"
[ -x "$HELPER_EXE" ] || fail "no password helper executable at ${HELPER_EXE#"$APP/"}"
[ -s "$RES/AppIcon.icns" ] || fail "missing Contents/Resources/AppIcon.icns"
[ -s "$HELPER_APP/Contents/Resources/AppIcon.icns" ] || fail "missing the helper's AppIcon.icns"
APP_BUNDLE="$RES/tankard_TankardApp.bundle"
MODEL_BUNDLE="$RES/tankard_TankardAppModel.bundle"
for b in "$APP_BUNDLE" "$MODEL_BUNDLE"; do
    [ -d "$b" ] || fail "missing Contents/Resources/$(basename "$b") (the app would fall back to Bundle.module's build path)"
done
# One array element per line, read by index (`plutil -extract KEY raw` on an
# array prints its count). Not `-extract … json | tr | while read`: plutil's
# JSON has no trailing newline, so `read` dropped the last language.
plist_strings() { # plist key
    local n i v
    [ "$(plutil -type "$2" "$1" 2>/dev/null)" = array ] || return 1
    n=$(plutil -extract "$2" raw -o - "$1") || return 1
    for ((i = 0; i < n; i++)); do
        v=$(plutil -extract "$2.$i" raw -o - "$1") || return 1
        printf '%s\n' "$v"
    done
}
LANGS=()
LANG_LIST=$(plist_strings "$APP/Contents/Info.plist" CFBundleLocalizations) || fail "CFBundleLocalizations in Info.plist is missing or not an array of strings"
while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in */*|.*) fail "odd CFBundleLocalizations entry '$l'" ;; esac
    LANGS+=("$l")
done <<< "$LANG_LIST"
[ ${#LANGS[@]} -gt 0 ] || fail "Info.plist lists no CFBundleLocalizations"
for l in "${LANGS[@]}"; do
    [ -s "$RES/$l.lproj/Localizable.strings" ] || fail "missing Contents/Resources/$l.lproj/Localizable.strings"
    [ -s "$HELPER_APP/Contents/Resources/$l.lproj/Localizable.strings" ] || fail "missing the helper's $l.lproj/Localizable.strings"
done
extra=$(find "$APP" -mindepth 1 -maxdepth 1 ! -name Contents -exec basename {} \;)
[ -z "$extra" ] || fail "unexpected item(s) at the .app root: $extra"
stray=$(find "$APP/Contents" -maxdepth 2 -name '*.bundle' ! -path "$RES/*")
[ -z "$stray" ] || fail "resource bundle(s) outside Contents/Resources: $stray"
codesign --verify --deep --strict "$APP" 2>"$TMP/codesign" || { cat "$TMP/codesign" >&2; fail "codesign --verify --deep --strict failed on the unzipped app"; }
TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
case "$TEAM" in ''|"not set") SIGNED="ad-hoc/unsigned (TANKARD_* switches honoured)" ; TEAM="" ;;
    *) SIGNED="Team ID $TEAM (TANKARD_* switches ignored by design)" ;; esac
if [ -n "$TEAM" ]; then
    # A Developer ID release: the zip's copy must carry the notarization
    # ticket and pass Gatekeeper as it is.
    xcrun stapler validate "$APP" >"$TMP/stapler" 2>&1 || { cat "$TMP/stapler" >&2; fail "the unzipped app has no valid notarization ticket"; }
    spctl -a -t exec -vv "$APP" 2>"$TMP/spctl" || { cat "$TMP/spctl" >&2; fail "Gatekeeper rejects the unzipped app"; }
    SIGNED="$SIGNED, stapled, Gatekeeper accepts"
fi
echo "layout ok: Tankard, TankardPassword.app/$HELPER_NAME, AppIcon.icns, 2 resource bundles in Contents/Resources, ${#LANGS[@]} localizations (${LANGS[*]}) in app and helper; signature valid, $SIGNED"

# 2. Hide the build machine's fallbacks.
ROOTS=()
while IFS= read -r r; do [ -n "$r" ] && ROOTS+=("$r"); done < <(
    { strings -a "$EXE" "$HELPER_EXE" \
        | sed -E -n 's#^(/.+)/Sources/(TankardApp|TankardAppModel|TankardCore|AskpassSupport|tankard-askpass|tankard)/.+\.swift$#\1#p'
      echo "$HERE"; } | sort -u)
TARGETS=()
for r in "${ROOTS[@]}"; do
    TARGETS+=("$r/.build" "$r/Resources" "$r/Sources/TankardApp/Resources" "$r/Sources/TankardAppModel/Resources")
done
MODULE_PATHS=()
# Only build paths inside a checkout root: a system *.bundle literal must
# never be renamed.
while IFS= read -r b; do
    [ -n "$b" ] || continue
    for r in "${ROOTS[@]}"; do
        case "$b" in "$r"/*) MODULE_PATHS+=("${b%/}"); break ;; esac
    done
done < <(
    strings -a "$EXE" "$HELPER_EXE" | grep -E '^/.+\.bundle/?$' | sort -u || true)
TARGETS+=(${MODULE_PATHS[@]+"${MODULE_PATHS[@]}"})
echo "checkout root(s): ${ROOTS[*]}; Bundle.module build path(s) compiled in: ${#MODULE_PATHS[@]}"
for p in ${MODULE_PATHS[@]+"${MODULE_PATHS[@]}"}; do echo "  $p"; done
for d in "${TARGETS[@]}"; do
    [ ! -e "$d.smoke-hidden" ] || fail "$d.smoke-hidden exists (an interrupted earlier run?). Restore it: mv '$d.smoke-hidden' '$d'"
done
for d in "${TARGETS[@]}"; do
    case "$d" in "$TMP"/*) continue ;; esac
    if [ -e "$d" ]; then
        HIDDEN+=("$d")   # first: restore() skips a path that was never moved
        mv "$d" "$d.smoke-hidden"
        echo "hid build-machine fallback $d (restored on exit)"
    fi
done
for d in "${TARGETS[@]}"; do [ ! -e "$d" ] || fail "fallback path still exists during the smoke: $d"; done

# 3. The resource bundles load from the unzipped app, as the app reads them.
cat > "$TMP/resources.js" <<'JS'
ObjC.import('Foundation');
function run(argv) {
    var res = argv[0], out = [];
    function open(name) {
        var b = $.NSBundle.bundleWithPath(res + '/' + name);
        if (!b || b.isNil()) throw new Error('NSBundle could not open ' + name);
        return b;
    }
    function need(b, label, name, ext, sub) {
        var u = sub ? b.URLForResourceWithExtensionSubdirectory(name, ext, sub) : b.URLForResourceWithExtension(name, ext);
        if (!u || u.isNil()) throw new Error(label + ': no ' + (sub ? sub + '/' : '') + name + '.' + ext);
        var d = $.NSData.dataWithContentsOfURL(u);
        if (!d || d.isNil() || d.length < 1) throw new Error(label + ': empty ' + name + '.' + ext);
        if (ext === 'png' && $.NSImage.alloc.initWithData(d).isNil()) throw new Error(label + ': ' + name + '.png is not an image');
        if (ext === 'json') {
            var err = Ref();
            if ($.NSJSONSerialization.JSONObjectWithDataOptionsError(d, 0, err).isNil()) throw new Error(label + ': ' + name + '.json does not parse');
        }
        out.push(name + '.' + ext);
    }
    ObjC.import('AppKit');
    var app = open('tankard_TankardApp.bundle');
    need(app, 'tankard_TankardApp.bundle', 'tankard-mark', 'png');
    need(app, 'tankard_TankardApp.bundle', 'intelbrew-mug', 'png');
    var model = open('tankard_TankardAppModel.bundle');
    ['arm64-api-info', 'arm64-tap-info', 'discover-api-formula'].forEach(function (n) {
        need(model, 'tankard_TankardAppModel.bundle', n, 'json', 'Demo');
    });
    var demo = model.URLsForResourcesWithExtensionSubdirectory('json', 'Demo');
    return out.join(', ') + '; ' + (demo.isNil() ? 0 : demo.count) + ' demo JSON files';
}
JS
loaded=$(with_alarm 30 osascript -l JavaScript "$TMP/resources.js" "$RES" 2>&1) || fail "resource bundles did not load: $loaded"
echo "resources ok (fallbacks hidden): $loaded"

# 4. A real launch, demo data only, Homebrew walled off.
SANDBOX="$TMP/no-homebrew.sb"
DENIED=(/opt/homebrew /usr/local/Homebrew /usr/local/Cellar /usr/local/Caskroom /usr/local/bin/brew)
# A probe the profile also denies, so the self-test proves the profile
# applies even on a machine with none of the Homebrew paths.
PROBE="$TMP/deny-probe"
mkdir "$PROBE" && : > "$PROBE/brew"
cat > "$SANDBOX" <<SB
(version 1)
(allow default)
(deny file-read* file-write* process-exec*
    (subpath "/opt/homebrew")
    (subpath "/usr/local/Homebrew")
    (subpath "/usr/local/Cellar")
    (subpath "/usr/local/Caskroom")
    (literal "/usr/local/bin/brew")
    (subpath "$PROBE"))
SB
# Self-test: sandbox-exec runs and allows the rest (else a failing probe
# below would prove nothing), the probe is hidden, and so is every denied
# path that exists on this machine.
sandbox-exec -f "$SANDBOX" /bin/test -d "$TMP" \
    || fail "sandbox-exec could not run /bin/test with the profile (or it denies more than Homebrew)"
if sandbox-exec -f "$SANDBOX" /bin/test -e "$PROBE/brew"; then
    fail "the sandbox profile does not apply (its probe $PROBE/brew is visible inside it)"
fi
if sandbox-exec -f "$SANDBOX" /bin/test -e "$PROBE"; then
    fail "the sandbox profile does not hide the probe directory $PROBE"
fi
HB_PRESENT=()
for d in "${DENIED[@]}"; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    HB_PRESENT+=("$d")
    if sandbox-exec -f "$SANDBOX" /bin/test -e "$d"; then fail "the sandbox profile does not hide $d"; fi
done
echo "sandbox ok: probe hidden; Homebrew path(s) present here and hidden inside: ${HB_PRESENT[*]:-none}"
# The launched app's environment: no TANKARD_* but TANKARD_DEMO=1, no
# HOMEBREW_* but HOMEBREW_NO_AUTO_UPDATE=1, and a PATH without any folder
# under a denied path or holding a brew executable.
ENV_CLEAN=(env)
for v in $(env | sed -n 's/^\(TANKARD_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(HOMEBREW_[A-Za-z0-9_]*\)=.*/\1/p'); do ENV_CLEAN+=(-u "$v"); done
CLEAN_PATH=""
IFS=: read -r -a PATH_DIRS <<< "$PATH"
for p in ${PATH_DIRS[@]+"${PATH_DIRS[@]}"}; do
    [ -n "$p" ] || continue
    case "$p" in /opt/homebrew|/opt/homebrew/*|/usr/local/Homebrew|/usr/local/Homebrew/*|/usr/local/Cellar|/usr/local/Cellar/*|/usr/local/Caskroom|/usr/local/Caskroom/*) continue ;; esac
    if [ -e "$p/brew" ]; then continue; fi
    CLEAN_PATH="${CLEAN_PATH:+$CLEAN_PATH:}$p"
done
ENV_CLEAN+=(PATH="${CLEAN_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" TANKARD_DEMO=1 HOMEBREW_NO_AUTO_UPDATE=1)

# Every name a crash report from this zip could carry: Tankard, the helper
# (TankardPassword.app reports as TankardPassword or tankard-askpass), and
# each bundle's CFBundleExecutable/CFBundleName plus every file in a
# Contents/MacOS folder inside the unzipped app.
NAMES=(Tankard TankardPassword "$EXE_NAME" "$HELPER_NAME")
while IFS= read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(
    {
        find "$APP" -path '*/Contents/Info.plist' -type f -print0 | while IFS= read -r -d '' pl; do
            plutil -extract CFBundleExecutable raw -o - "$pl" 2>/dev/null || true
            plutil -extract CFBundleName raw -o - "$pl" 2>/dev/null || true
        done
        find "$APP" -path '*/Contents/MacOS/*' -type f -exec basename {} \;
    } | sort -u)
# ~/Library's and /Library's report folders, recursively (Retired/ too).
echo "crash-report names: $(printf '%s\n' "${NAMES[@]}" | sort -u | paste -sd ' ' -)"
REPORT_DIRS=("$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports)
# "basename<TAB>path" for every report named after one of NAMES, sorted.
# New = a basename not in the listing taken before the launch (by name, not
# mtime: ReportCrash touches older reports, and moves some into Retired/,
# when it trims the folder).
matching_reports() {
    local d f base n
    for d in "${REPORT_DIRS[@]}"; do
        [ -d "$d" ] || continue
        while IFS= read -r -d '' f; do
            base=${f##*/}
            for n in "${NAMES[@]}"; do
                case "$base" in "$n"[-_.]*) printf '%s\t%s\n' "$base" "$f"; break ;; esac
            done
        done < <(find "$d" \( -name '*.ips' -o -name '*.crash' \) -type f -print0 2>/dev/null)
    done | sort
}
BEFORE="$TMP/reports-before"
matching_reports | cut -f1 | sort -u > "$BEFORE"
new_reports() { matching_reports | awk -F '\t' 'NR == FNR { seen[$0] = 1; next } !($1 in seen) { print $2 }' "$BEFORE" -; }
report_pid() { # file -> the crashed process's pid, or "?"
    local p
    p=$(sed -E -n 's/.*"pid" *: *([0-9]+).*/\1/p; s/^Process: .*\[([0-9]+)\].*/\1/p' "$1" 2>/dev/null | head -1)
    echo "${p:-?}"
}
# "file (pid N: this launch|...)" per new report, joined with "; ".
describe_reports() { # pid
    local f p out=()
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        p=$(report_pid "$f")
        if [ "$p" = "$1" ]; then out+=("$f (pid $p: this launch)"); else out+=("$f (pid $p: a helper or another Tankard run)"); fi
    done < <(new_reports)
    [ ${#out[@]} = 0 ] || { local IFS=';'; echo "${out[*]}" | sed 's/;/; /g'; }
}
# Waits up to N s for a new report carrying this pid (ReportCrash can take
# several seconds), then returns.
wait_for_report() { # pid seconds
    local i
    for i in $(seq 1 $(($2 * 4))); do
        case "$(describe_reports "$1")" in *"pid $1: this launch"*) return 0 ;; esac
        sleep 0.25
    done
}
# Waits up to N s for any new report (a helper's, or a crash on quit), then
# returns; it returns as soon as one shows up.
wait_for_any_report() { # seconds
    local i
    for i in $(seq 1 $(($1 * 4))); do
        [ -z "$(new_reports)" ] || return 0
        sleep 0.25
    done
}
CRASH_WAIT=15   # ReportCrash can take several seconds; same on every path

"${ENV_CLEAN[@]}" sandbox-exec -f "$SANDBOX" "$EXE" -ApplePersistenceIgnoreState YES >"$TMP/stdout" 2>"$TMP/stderr" &
PID=$!
LAUNCHED=$PID
echo "launched pid $PID (TANKARD_DEMO=1, Homebrew sandboxed off); watching for ${SECONDS_UP}s"
for _ in $(seq 1 $((SECONDS_UP * 4))); do
    if ! kill -0 "$PID" 2>/dev/null; then
        rc=0; wait "$PID" || rc=$?; PID=""
        # Killed by a signal: give ReportCrash time to write its report.
        if [ $rc -gt 128 ]; then wait_for_report "$LAUNCHED" $CRASH_WAIT; else wait_for_any_report $CRASH_WAIT; fi
        echo "--- stderr ---" >&2; tail -40 "$TMP/stderr" >&2
        crash=$(describe_reports "$LAUNCHED")
        fail "Tankard exited within ${SECONDS_UP}s (exit $rc)${crash:+; crash report(s): $crash}"
    fi
    sleep 0.25
done
with_alarm 10 osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($PID); if (a) a.terminate; ''" >/dev/null 2>&1 \
    || echo "note: the Quit event's osascript failed or hit its 10 s alarm" >&2
quit=0
for _ in $(seq 1 32); do kill -0 "$PID" 2>/dev/null || { quit=1; break; }; sleep 0.25; done
if [ $quit = 0 ]; then
    kill -9 "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""
    fail "Tankard was up ${SECONDS_UP}s but did not quit within 8 s of a Quit event (a prompt?)"
fi
rc=0; wait "$PID" || rc=$?; PID=""
[ $rc = 0 ] || { tail -40 "$TMP/stderr" >&2; fail "Tankard quit with exit code $rc"; }
if grep -E "could not load resource bundle|Fatal error" "$TMP/stderr" >&2; then fail "Tankard logged a fatal resource error (above)"; fi
echo "launch ok: up ${SECONDS_UP}s, quit cleanly on a Quit event (exit 0)"

# 5. Crash reports from any run above (also a helper's, or a crash on quit).
wait_for_any_report $CRASH_WAIT
crash=$(describe_reports "$LAUNCHED")
[ -z "$crash" ] || fail "new crash report(s): $crash"

NHIDDEN=${#HIDDEN[@]}
restore
[ $RESTORE_FAILED = 0 ] || fail "could not restore every hidden path (see above)"
echo "SMOKE PASS: $(basename "$ZIP") unzipped fresh; Tankard ran ${SECONDS_UP}s (TANKARD_DEMO=1, Homebrew sandboxed off) and quit cleanly with ${NHIDDEN} build-machine fallback path(s) hidden; resource bundles load; no crash report"
