#!/bin/bash
# Builds Tankard.app from the SwiftPM TankardApp target. Command Line Tools
# only: no Xcode project, no asset catalog, no actool.
#
#   Scripts/bundle-app.sh                 host architecture, ad-hoc signed
#   Scripts/bundle-app.sh --universal     x86_64 + arm64 in one binary
#   Scripts/bundle-app.sh --arch x86_64   one specific architecture
#   Scripts/bundle-app.sh --no-sign       leave it unsigned (release.sh signs)
#   Scripts/bundle-app.sh --out DIR       where Tankard.app goes (default: dist)
#
# --universal needs a SwiftPM that can build several architectures in one go.
# SwiftPM 6.1+ (its own build system) can, under the CLT alone; SwiftPM 6.0
# (CLT 16.x, as on the macOS 14 VM) hands multi-arch builds to xcbuild, which
# only ships with Xcode. Without it, build each architecture on its own and
# join them: see "Universal builds" in the README.
#
# Version: TANKARD_VERSION (default from the latest v* git tag, else 0.2.0).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=dist
SIGN=adhoc
ARCH_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) ARCH_ARGS=(--arch x86_64 --arch arm64) ;;
        --arch) ARCH_ARGS+=(--arch "$2"); shift ;;
        --out) OUT=$2; shift ;;
        --no-sign) SIGN=none ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "bundle-app.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

VERSION=${TANKARD_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}
VERSION=${VERSION:-0.2.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

echo "==> swift build -c release ${ARCH_ARGS[*]:-}"
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product TankardApp
BIN=$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)

APP="$OUT/Tankard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TankardApp" "$APP/Contents/MacOS/Tankard"
# SwiftPM resource bundles (logo, demo data). The app looks for them in
# Contents/Resources; Bundle.main.bundleURL (the .app root) would break the
# code signature's sealing rules.
for b in tankard_TankardApp.bundle tankard_TankardAppModel.bundle; do
    if [ -d "$BIN/$b" ]; then
        cp -R "$BIN/$b" "$APP/Contents/Resources/"
    else
        echo "bundle-app.sh: missing $BIN/$b" >&2
        exit 1
    fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>net.mindtricks.tankard</string>
    <key>CFBundleName</key>
    <string>Tankard</string>
    <key>CFBundleDisplayName</key>
    <string>Tankard</string>
    <key>CFBundleExecutable</key>
    <string>Tankard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ "$SIGN" = adhoc ]; then
    # Ad-hoc: no identity, no Gatekeeper approval. See the README's
    # quarantine note. No App Sandbox: brew can't run inside one.
    codesign -s - --force --deep "$APP"
    codesign --verify --deep --strict "$APP"
fi

echo "==> $APP ($VERSION, build $BUILD): $(lipo -archs "$APP/Contents/MacOS/Tankard"), signing: $SIGN"
