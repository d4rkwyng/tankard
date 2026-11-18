#!/bin/bash
# 0.8.4: the signed-pair self-update test, mandatory for every rc. The
# notarized rc against the notarized release before it, as users get them:
#
#   Scripts/rc-selfupdate-signed.sh RC_TAG [--prev TAG] [--new-zip ZIP]
#       [--old-zip ZIP] [--out DIR] [--verify-only]
#
#   RC_TAG        the rc's tag, e.g. v0.8.4-rc1 (its Tankard.zip, from the
#                 draft release the release workflow made)
#   --prev TAG    the release to update from (default: the latest
#                 non-prerelease, non-draft release, e.g. v0.8.3)
#   --new-zip ZIP / --old-zip ZIP
#                 use this Tankard.zip instead of downloading it
#   --out DIR     where everything goes (default: a new folder in $TMPDIR)
#   --verify-only download and verify both, then stop before the e2e run
#
# 1. Downloads both Tankard.zip files with `gh release download` from
#    d4rkwyng/tankard (drafts need a gh login with access to the repo; if
#    that fails, download the rc's zip from the draft page and pass
#    --new-zip) and unzips each with ditto into its own folder.
# 2. Verifies both: `codesign --verify --deep --strict`, `spctl -a -vv -t
#    exec` says "source=Notarized Developer ID", `stapler validate`, the
#    sudo helper (if the build has one) signed with the hardened runtime, a
#    Developer ID and a secure timestamp, one Team ID for both, each
#    CFBundleShortVersionString matching its tag, and the rc newer (semver).
# 3. Runs Scripts/e2e-selfupdate.sh (this checkout's) on the pair. It needs
#    an unlocked GUI session; an unanswered Gatekeeper prompt blocks it.
#    Release builds honour the TANKARD_E2E* script hooks (no #if DEBUG),
#    and every release since 0.8.3 has the self-update steps. But before
#    0.8.4 the relaunch passed the whole environment to the new copy, so
#    the rc, relaunched by such an OLD, runs OLD's script again and quits:
#    phase A can't judge that pair. Then (found by looking for 0.8.4's
#    relaunch-identity string in OLD's binary):
#      - phases B and C with OLD = the previous release (C is the real
#        shipped OLD with a sheet open, replaced by the notarized rc);
#      - phase A with OLD = the rc's own tag rebuilt here as
#        <rc version>-e2e.0 (ad-hoc signed, or with TANKARD_SIGN_ID), NEW =
#        the notarized rc: the rc's relaunch code installing and starting
#        the notarized, brew-quarantined rc. Not the shipped OLD's relaunch;
#        that one 0.8.3 rc2 already ran with ad-hoc builds.
#    Once the previous release is 0.8.4 or later, all three phases run on
#    the two notarized builds.
#
# Installs nothing itself; e2e-selfupdate.sh installs and removes its own
# throwaway tap, cask and /Applications/Tankard.app (and refuses to start if
# any of them, or a running Tankard, is already there).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_DIR=$(pwd)
GH_REPO=d4rkwyng/tankard

RC= PREV= NEW_ZIP= OLD_ZIP= OUT= VERIFY_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prev) PREV=${2:-}; shift ;;
        --new-zip) NEW_ZIP=${2:-}; shift ;;
        --old-zip) OLD_ZIP=${2:-}; shift ;;
        --out) OUT=${2:-}; shift ;;
        --verify-only) VERIFY_ONLY=1 ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        -*) echo "rc-selfupdate-signed.sh: unknown option $1" >&2; exit 2 ;;
        *) [ -z "$RC" ] || { echo "rc-selfupdate-signed.sh: one RC_TAG only (got $RC and $1)" >&2; exit 2; }
           RC=$1 ;;
    esac
    shift
done
[ -n "$RC" ] || { echo "usage: $0 RC_TAG [--prev TAG] [--new-zip ZIP] [--old-zip ZIP] [--out DIR] [--verify-only]" >&2; exit 2; }
for z in "$NEW_ZIP" "$OLD_ZIP"; do
    [ -z "$z" ] || [ -f "$z" ] || { echo "rc-selfupdate-signed.sh: no such zip: $z" >&2; exit 2; }
done
TAGRE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
[[ $RC =~ $TAGRE ]] || { echo "rc-selfupdate-signed.sh: '$RC' is not a vX.Y.Z[-suffix] tag" >&2; exit 2; }

fail() { echo "rc-selfupdate-signed.sh: $*" >&2; exit 1; }

if [ -z "$PREV" ]; then
    PREV=$(gh release list -R "$GH_REPO" --exclude-drafts --exclude-pre-releases -L 1 --json tagName -q '.[0].tagName') \
        || fail "gh release list failed (gh auth status?)"
    [ -n "$PREV" ] || fail "no published release in $GH_REPO"
fi
[[ $PREV =~ $TAGRE ]] || fail "--prev '$PREV' is not a vX.Y.Z[-suffix] tag"
[ "$PREV" != "$RC" ] || fail "the rc and the previous release are the same tag ($RC)"

[ -n "$OUT" ] || OUT=$(mktemp -d "${TMPDIR:-/tmp}/tankard-rc-selfupdate.$RC.XXXXXX")
mkdir -p "$OUT" || fail "can't create $OUT"
OUT=$(cd "$OUT" && pwd)
echo "rc $RC, previous release $PREV, output $OUT"

# MARK: 1. download and unzip
# get NAME TAG LOCALZIP: $OUT/NAME/Tankard.app
get() {
    local name=$1 tag=$2 zip=$3 d="$OUT/$1"
    rm -rf "$d"; mkdir -p "$d/zip" "$d/app"
    if [ -n "$zip" ]; then
        echo "+ cp $zip $d/zip/Tankard.zip"
        cp "$zip" "$d/zip/Tankard.zip" || return 1
    else
        echo "+ gh release download $tag -R $GH_REPO -p Tankard.zip -D $d/zip"
        gh release download "$tag" -R "$GH_REPO" -p Tankard.zip -D "$d/zip" || {
            echo "rc-selfupdate-signed.sh: couldn't download $tag's Tankard.zip (a draft needs a gh login with access to $GH_REPO; else pass the zip with --$name-zip)" >&2
            return 1
        }
    fi
    echo "  sha256 $(shasum -a 256 "$d/zip/Tankard.zip" | cut -d' ' -f1)"
    echo "+ ditto -x -k $d/zip/Tankard.zip $d/app"
    ditto -x -k "$d/zip/Tankard.zip" "$d/app" || return 1
    [ -d "$d/app/Tankard.app" ] || { echo "rc-selfupdate-signed.sh: no Tankard.app at the top of $tag's zip" >&2; return 1; }
}
get old "$PREV" "$OLD_ZIP" || fail "previous release $PREV: download/unzip failed"
get new "$RC" "$NEW_ZIP" || fail "rc $RC: download/unzip failed"
OLDAPP=$OUT/old/app/Tankard.app
NEWAPP=$OUT/new/app/Tankard.app

# MARK: 2. verify
FAILS=()
check() { # label command... (prints the command's output, records a failure)
    local label=$1 out rc; shift
    out=$("$@" 2>&1); rc=$?
    [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    /'
    if [ $rc = 0 ]; then echo "  ok   $label"; else echo "  FAIL $label (exit $rc)"; FAILS+=("$label"); fi
}
spctl_notarized() { # app
    local out; out=$(/usr/sbin/spctl -a -vv -t exec "$1" 2>&1); echo "$out"
    grep -q ': accepted$' <<<"$out" && grep -qx 'source=Notarized Developer ID' <<<"$out"
}
helper_signed() { # app: the 0.8.3 sudo helper, own Developer ID signature
    local h="$1/Contents/MacOS/tankard-askpass" out
    [ -e "$h" ] || { echo "no tankard-askpass (a build before 0.8.3)"; return 0; }
    out=$(codesign -dv --verbose=4 "$h" 2>&1)
    printf '%s\n' "$out" | grep -E '^(Identifier|Authority|Timestamp|TeamIdentifier|CodeDirectory)'
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\((.*,)?runtime(,.*)?\)' <<<"$out" || { echo "no hardened runtime"; return 1; }
    grep -q '^Authority=Developer ID Application:' <<<"$out" || { echo "not Developer ID"; return 1; }
    grep -q '^Timestamp=' <<<"$out" || { echo "no secure timestamp"; return 1; }
}
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
version() { plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist" 2>/dev/null; }
base() { local v=${1#v}; echo "${v%%-*}"; }   # v0.8.4-rc1 -> 0.8.4 (release.yml's TANKARD_VERSION)

for side in old new; do
    app=$OLDAPP tag=$PREV; [ $side = new ] && { app=$NEWAPP; tag=$RC; }
    echo "==> verify $side: $tag ($app)"
    check "$side codesign --verify --deep --strict" codesign --verify --deep --strict --verbose=2 "$app"
    check "$side spctl: Notarized Developer ID" spctl_notarized "$app"
    check "$side stapler validate" xcrun stapler validate "$app"
    check "$side tankard-askpass signature" helper_signed "$app"
    v=$(version "$app")
    check "$side version $v = $(base "$tag")" test "$v" = "$(base "$tag")"
done
TOLD=$(team "$OLDAPP"); TNEW=$(team "$NEWAPP")
echo "==> Team ID: old ${TOLD:-none}, new ${TNEW:-none}"
check "one Team ID" test -n "$TOLD" -a "$TOLD" = "$TNEW"
VOLD=$(version "$OLDAPP"); VNEW=$(version "$NEWAPP")
newer() { # a b: semver b > a (pre-release before release, as SelfUpdate.swift)
    /usr/bin/python3 -I - "$1" "$2" <<'PY'
import sys
def key(v):
    core, _, pre = v.partition("-")
    nums = tuple(int(x) for x in core.split("."))
    if not pre:
        return (nums, 1, ())
    return (nums, 0, tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split(".")))
try:
    sys.exit(0 if key(sys.argv[2]) > key(sys.argv[1]) else 1)
except ValueError:
    print("not a version: %s / %s" % (sys.argv[1], sys.argv[2])); sys.exit(2)
PY
}
check "rc $VNEW newer than $VOLD" newer "$VOLD" "$VNEW"
# 0.8.4's relaunch gives the new copy an idle e2e identity instead of the
# whole environment (AppManagement.relaunchEnvironment); its log text is
# the marker.
MARKER='relaunch: e2e identity dropped'
# grep -a on the binary itself: `strings | grep -q` under pipefail fails
# with SIGPIPE (141) exactly when grep finds the marker early.
has_marker() { grep -aqF "$MARKER" "$1/Contents/MacOS/Tankard"; }
OLD_RELAUNCH=no; has_marker "$OLDAPP" && OLD_RELAUNCH=yes
NEW_RELAUNCH=no; has_marker "$NEWAPP" && NEW_RELAUNCH=yes
echo "==> 0.8.4 relaunch identity: old $OLD_RELAUNCH, new $NEW_RELAUNCH"

{
    echo "rc $RC ($VNEW, team $TNEW), previous $PREV ($VOLD, team $TOLD)"
    echo "old relaunch identity: $OLD_RELAUNCH"
    [ ${#FAILS[@]} = 0 ] && echo "verify: PASS" || printf 'verify: FAIL %s\n' "${FAILS[@]}"
} | tee "$OUT/verify.txt"
[ ${#FAILS[@]} = 0 ] || exit 1

if [ $OLD_RELAUNCH = yes ]; then
    PLAN="A, B and C on the notarized pair"
else
    PLAN="B and C with OLD = $PREV; A with OLD = $RC rebuilt here as $VNEW-e2e.0 ($PREV's relaunch passes the script environment on)"
fi
echo "e2e plan: $PLAN" | tee -a "$OUT/verify.txt"
[ $NEW_RELAUNCH = yes ] || echo "NOTE: $RC lacks 0.8.4's relaunch identity: phase A can't pass with it as NEW (a build before 0.8.4?)" | tee -a "$OUT/verify.txt"
if [ $VERIFY_ONLY = 1 ]; then
    echo "--verify-only: stopping before Scripts/e2e-selfupdate.sh"
    exit 0
fi
[ $NEW_RELAUNCH = yes ] || fail "not running the e2e: $RC lacks 0.8.4's relaunch identity"
# 0.8.3's self-update script hooks (TANKARD_E2E_SELF_TAP, upgrade-self):
# phases A and C drive OLD with them.
grep -aqF TANKARD_E2E_SELF_TAP "$OLDAPP/Contents/MacOS/Tankard" \
    || fail "not running the e2e: $PREV has no self-update e2e hooks (before 0.8.3)"

# MARK: 3. the e2e run
RESULT=0
if [ $OLD_RELAUNCH = yes ]; then
    Scripts/e2e-selfupdate.sh --old "$OLDAPP" --new "$NEWAPP" --out "$OUT/e2e" || RESULT=1
else
    Scripts/e2e-selfupdate.sh --old "$OLDAPP" --new "$NEWAPP" --out "$OUT/e2e-BC" --phases BC || RESULT=1
    # OLD for A: the rc's tree at its tag, one pre-release lower.
    SRC="$OUT/old-a/src"; rm -rf "$OUT/old-a"; mkdir -p "$SRC"
    git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$RC" >/dev/null \
        || git -C "$REPO_DIR" fetch -q origin "refs/tags/$RC:refs/tags/$RC" \
        || fail "tag $RC isn't here and couldn't be fetched"
    echo "+ git archive $RC | tar -x -C $SRC"
    git -C "$REPO_DIR" archive "$RC" | tar -x -C "$SRC" || fail "git archive $RC failed"
    # The compiled version too (a throwaway tree): before 0.8.4's
    # TankardVersion.source/Info.plist rule the update check used the
    # literal, so a re-versioned build of an older tag would still call
    # itself the rc's version and see no update.
    sed -i '' -E "s/(static let (string|source)) = \"[^\"]*\"/\1 = \"$VNEW-e2e.0\"/" "$SRC/Sources/TankardCore/Version.swift" \
        && grep -qF "\"$VNEW-e2e.0\"" "$SRC/Sources/TankardCore/Version.swift" \
        || fail "couldn't set the version in $SRC/Sources/TankardCore/Version.swift"
    echo "+ TANKARD_VERSION=$VNEW-e2e.0 Scripts/bundle-app.sh --out $OUT/old-a"
    ( cd "$SRC" && TANKARD_VERSION="$VNEW-e2e.0" Scripts/bundle-app.sh --out "$OUT/old-a" ) > "$OUT/old-a/build.log" 2>&1 \
        || fail "building $RC as $VNEW-e2e.0 failed (see $OUT/old-a/build.log)"
    [ "$(version "$OUT/old-a/Tankard.app")" = "$VNEW-e2e.0" ] && grep -aqF "$VNEW-e2e.0" "$OUT/old-a/Tankard.app/Contents/MacOS/Tankard" \
        || fail "the rebuilt OLD isn't $VNEW-e2e.0 in both Info.plist and binary"
    if [ -n "${TANKARD_SIGN_ID:-}" ]; then
        # As release.sh: the helper first (its own identifier), then the app.
        SIGN=(codesign --force --options runtime --timestamp -s "$TANKARD_SIGN_ID")
        "${SIGN[@]}" --identifier net.mindtricks.tankard.askpass "$OUT/old-a/Tankard.app/Contents/MacOS/tankard-askpass" \
            && "${SIGN[@]}" "$OUT/old-a/Tankard.app" || fail "signing $OUT/old-a/Tankard.app with $TANKARD_SIGN_ID"
    fi
    Scripts/e2e-selfupdate.sh --old "$OUT/old-a/Tankard.app" --new "$NEWAPP" --out "$OUT/e2e-A" --phases A || RESULT=1
fi
echo "e2e plan: $PLAN"
for f in "$OUT"/e2e*/summary.txt; do [ -f "$f" ] && { echo "--- $f"; cat "$f"; }; done
[ $RESULT = 0 ] && echo "rc-selfupdate-signed: PASS" || echo "rc-selfupdate-signed: FAIL"
exit $RESULT
