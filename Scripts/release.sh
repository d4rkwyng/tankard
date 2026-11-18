#!/bin/bash
# Builds, signs (Developer ID), notarizes and staples Tankard.app, then zips
# it for distribution. Run on a Mac whose keychain holds a "Developer ID
# Application" certificate. The GitHub release workflow runs this too.
#
#   Scripts/release.sh [--dry-run] [--host-arch] [--skip-notarize] [--skip-launch-check]
#
#   --dry-run        print every command instead of running it (the identity
#                    lookup still runs: it only reads the keychain)
#   --host-arch      build only this Mac's architecture (default: universal)
#   --skip-notarize  sign and verify only
#   --skip-launch-check
#                    don't real-launch the signed app (Scripts/launch-check.sh);
#                    only for a Mac with no logged-in GUI session
#
# Settings (environment):
#   TANKARD_SIGN_ID          signing identity; default: the first
#                            "Developer ID Application:" from
#                            `security find-identity -v -p codesigning`
#   TANKARD_NOTARY_PROFILE   notarytool keychain profile (default: tankard),
#                            made once with `xcrun notarytool store-credentials tankard`
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#                            used instead of the profile when all three are set (CI)
#   TANKARD_VERSION          version string (default: TankardVersion.source in
#                            Sources/TankardCore/Version.swift); must equal it
#
# Output: dist/Tankard.app (stapled) and dist/Tankard.zip; when notarizing,
# also dist/notary-result.json (notarytool submit's answer) and
# dist/notary-log.json (Apple's log for that submission, accepted or not).
#
# Hardened runtime needs no entitlements here: the app is plain Swift, loads
# no third-party libraries or plug-ins, uses no JIT, and starts brew with
# posix_spawn (a child process is not restricted by the parent's hardened
# runtime). No App Sandbox, because brew can't run inside one.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0
UNIVERSAL=1
NOTARIZE=1
LAUNCH_CHECK=1
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --host-arch) UNIVERSAL=0 ;;
        --skip-notarize) NOTARIZE=0 ;;
        --skip-launch-check) LAUNCH_CHECK=0 ;;
        -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "release.sh: unknown option $a" >&2; exit 2 ;;
    esac
done

# Prints the command; runs it unless --dry-run. Secrets are masked.
run() {
    local shown=() hide=0
    for w in "$@"; do
        if [ $hide = 1 ]; then shown+=("****"); hide=0; continue; fi
        shown+=("$(printf '%q' "$w")")
        [ "$w" = "--password" ] && hide=1
    done
    echo "+ ${shown[*]}"
    [ $DRY = 1 ] || "$@"
}

fail() { echo "release.sh: $*" >&2; exit 1; }

APP=dist/Tankard.app
ZIP=dist/Tankard.zip
SUBMIT_ZIP=dist/Tankard-notarize.zip

# 0. The version. A release's Info.plist (TANKARD_VERSION, the tag's in CI)
#    must be the source's: the app reports the plist's version and the CLI
#    the source's, and they must not disagree in what ships.
SOURCE_VERSION=$(sed -n 's/.*static let source = "\([^"]*\)".*/\1/p' Sources/TankardCore/Version.swift)
[ -n "$SOURCE_VERSION" ] || fail "no TankardVersion.source in Sources/TankardCore/Version.swift"
if [ -n "${TANKARD_VERSION:-}" ] && [ "$TANKARD_VERSION" != "$SOURCE_VERSION" ]; then
    msg="TANKARD_VERSION $TANKARD_VERSION differs from TankardVersion.source $SOURCE_VERSION (bump Sources/TankardCore/Version.swift, or tag the version it says)"
    [ $DRY = 1 ] || fail "$msg"
    echo "(dry run) $msg" >&2
fi
echo "Version: ${TANKARD_VERSION:-$SOURCE_VERSION}"

# 1. Signing identity.
ID=${TANKARD_SIGN_ID:-}
if [ -z "$ID" ]; then
    echo "+ security find-identity -v -p codesigning"
    ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$ID" ]; then
    msg='no "Developer ID Application:" signing identity in the keychain. Install your Developer ID certificate, or set TANKARD_SIGN_ID.'
    [ $DRY = 1 ] || fail "$msg"
    echo "(dry run) $msg Using a placeholder." >&2
    ID="Developer ID Application: EXAMPLE (TEAMID)"
fi
echo "Signing identity: $ID"

# 2. Notary credentials.
NOTARY_ARGS=()
if [ $NOTARIZE = 1 ]; then
    if [ -n "${NOTARY_APPLE_ID:-}" ] || [ -n "${NOTARY_TEAM_ID:-}" ] || [ -n "${NOTARY_PASSWORD:-}" ]; then
        [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] \
            || fail "set all three of NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD, or none (to use a keychain profile)"
        NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
    else
        NOTARY_ARGS=(--keychain-profile "${TANKARD_NOTARY_PROFILE:-tankard}")
    fi
fi

# 3. Build and assemble (unsigned), sharing bundle-app.sh.
BUNDLE_ARGS=(--no-sign)
if [ $UNIVERSAL = 1 ]; then
    BUNDLE_ARGS+=(--universal)
else
    echo "NOTE: --host-arch: building $(uname -m) only; this release will not run on the other architecture." >&2
fi
run Scripts/bundle-app.sh "${BUNDLE_ARGS[@]}"
if [ $DRY = 0 ] && [ $UNIVERSAL = 1 ]; then
    archs=$(lipo -archs "$APP/Contents/MacOS/Tankard")
    case "$archs" in
        *x86_64*arm64*|*arm64*x86_64*) ;;
        *) fail "expected a universal binary, got: $archs" ;;
    esac
fi

# 4. Sign: nested code first, then the app itself (no --deep: each piece
#    gets its own explicit signature with the hardened runtime).
SIGN=(codesign --force --options runtime --timestamp -s "$ID")
if [ $DRY = 0 ]; then
    while IFS= read -r -d '' f; do
        run "${SIGN[@]}" "$f"
    done < <(find "$APP/Contents" \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -print0)
fi
# 0.8.3: the sudo password helper, a second executable in Contents/MacOS:
# its own Developer ID signature with the hardened runtime and a secure
# timestamp (notarization requires both), before the app is sealed.
HELPER="$APP/Contents/MacOS/tankard-askpass"
[ $DRY = 1 ] || [ -x "$HELPER" ] || fail "missing $HELPER (bundle-app.sh builds it)"
run "${SIGN[@]}" --identifier net.mindtricks.tankard.askpass "$HELPER"
run "${SIGN[@]}" "$APP"
run codesign --verify --strict --deep --verbose=2 "$APP"
run codesign --verify --strict --verbose=2 "$HELPER"

# 4b. Launch the signed app for real (no demo, no snapshot) and fail the
#     release if it crashes or quits. 0.3.0 shipped a launch crash that only
#     the signed release build showed, and only on a real launch; the local
#     build and every demo/snapshot run looked fine. Several runs, because
#     that crash hit about half of all launches.
if [ $LAUNCH_CHECK = 1 ]; then
    run Scripts/launch-check.sh "$APP" --runs 5 --seconds 10
else
    echo "NOTE: --skip-launch-check: the signed app was not launched. Run Scripts/launch-check.sh $APP before publishing." >&2
fi

if [ $NOTARIZE = 0 ]; then
    run ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Signed but not notarized: $ZIP"
    exit 0
fi

# 5. Notarize, staple, verify with Gatekeeper.
run rm -f "$SUBMIT_ZIP"
run ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
RESULT=dist/notary-result.json
# 0.8.4: Apple's log for the submission, fetched after every submission
# (Accepted or not) and printed, so CI keeps it (release.yml uploads both
# files as a workflow artifact, also when this step fails). It holds the
# submission id, status, archive name, upload date, the zip's sha256, the
# signed binaries' cdhashes ("ticketContents") and the issues list (path,
# message, docUrl per issue); no Apple ID, password or certificate.
NOTARY_LOG=dist/notary-log.json
notary_log() { # submission id
    local i
    run rm -f "$NOTARY_LOG"
    # The log can lag the status by a few seconds; three tries.
    for i in 1 2 3; do
        if run xcrun notarytool log "${NOTARY_ARGS[@]}" "$1" "$NOTARY_LOG"; then
            [ $DRY = 1 ] || { echo "--- $NOTARY_LOG"; cat "$NOTARY_LOG"; echo; echo "---"; }
            return 0
        fi
        [ $i = 3 ] || sleep 10
    done
    echo "release.sh: could not fetch the notary log for $1" >&2
    return 1
}
if [ $DRY = 1 ]; then
    run xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json
    notary_log "<submission-id>"
else
    run rm -f "$RESULT" "$NOTARY_LOG"
    echo "+ xcrun notarytool submit $SUBMIT_ZIP ${NOTARY_ARGS[0]} … --wait --output-format json"
    # Not under `set -e`: an Invalid submission must still get its log.
    SUBMIT_RC=0
    xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json | tee "$RESULT" || SUBMIT_RC=$?
    echo
    STATUS=$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)
    SUB_ID=$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)
    LOG_OK=0
    if [ -n "$SUB_ID" ]; then
        notary_log "$SUB_ID" && LOG_OK=1
    else
        echo "release.sh: no submission id in $RESULT (notarytool exit $SUBMIT_RC): nothing was submitted, no log" >&2
    fi
    if [ "$STATUS" != "Accepted" ]; then
        fail "notarization status: $STATUS (notarytool exit $SUBMIT_RC). Apple's log: $([ $LOG_OK = 1 ] && echo "$NOTARY_LOG, printed above" || echo "xcrun notarytool log ${SUB_ID:-<id>} ${NOTARY_ARGS[0]} …")"
    fi
    # Accepted with no log: the release goes on (the ticket is what ships),
    # but say so; the workflow artifact will lack notary-log.json.
    [ $LOG_OK = 1 ] || echo "WARNING: notarization Accepted, but Apple's log could not be fetched" >&2
fi
run xcrun stapler staple "$APP"
run xcrun stapler validate "$APP"
run spctl -a -vv -t exec "$APP"

# 6. The distribution zip (stapled app).
run rm -f "$ZIP" "$SUBMIT_ZIP"
run ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release ready: $ZIP"
