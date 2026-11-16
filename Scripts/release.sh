#!/bin/bash
# Builds, signs (Developer ID), notarizes and staples Tankard.app, then zips
# it for distribution. Run on a Mac whose keychain holds a "Developer ID
# Application" certificate. The GitHub release workflow runs this too.
#
#   Scripts/release.sh [--dry-run] [--host-arch] [--skip-notarize]
#
#   --dry-run        print every command instead of running it (the identity
#                    lookup still runs: it only reads the keychain)
#   --host-arch      build only this Mac's architecture (default: universal)
#   --skip-notarize  sign and verify only
#
# Settings (environment):
#   TANKARD_SIGN_ID          signing identity; default: the first
#                            "Developer ID Application:" from
#                            `security find-identity -v -p codesigning`
#   TANKARD_NOTARY_PROFILE   notarytool keychain profile (default: tankard),
#                            made once with `xcrun notarytool store-credentials tankard`
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#                            used instead of the profile when all three are set (CI)
#   TANKARD_VERSION          version string (default: latest v* tag)
#
# Output: dist/Tankard.app (stapled) and dist/Tankard.zip.
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
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --host-arch) UNIVERSAL=0 ;;
        --skip-notarize) NOTARIZE=0 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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
else
    echo "+ (sign any nested .dylib/.framework/.xpc/.appex first; this app has none today)"
fi
run "${SIGN[@]}" "$APP"
run codesign --verify --strict --deep --verbose=2 "$APP"

if [ $NOTARIZE = 0 ]; then
    run ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Signed but not notarized: $ZIP"
    exit 0
fi

# 5. Notarize, staple, verify with Gatekeeper.
run rm -f "$SUBMIT_ZIP"
run ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
RESULT=dist/notary-result.json
if [ $DRY = 1 ]; then
    run xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json
else
    echo "+ xcrun notarytool submit $SUBMIT_ZIP ${NOTARY_ARGS[0]} … --wait --output-format json"
    xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json | tee "$RESULT"
    echo
    STATUS=$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)
    if [ "$STATUS" != "Accepted" ]; then
        SUB_ID=$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || echo "<id>")
        fail "notarization status: $STATUS. Details: xcrun notarytool log $SUB_ID ${NOTARY_ARGS[0]} …"
    fi
fi
run xcrun stapler staple "$APP"
run xcrun stapler validate "$APP"
run spctl -a -vv -t exec "$APP"

# 6. The distribution zip (stapled app).
run rm -f "$ZIP" "$SUBMIT_ZIP"
run ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release ready: $ZIP"
