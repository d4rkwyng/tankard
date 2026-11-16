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
# --universal first tries one multi-arch `swift build`. Newer SwiftPM does
# that under the CLT alone; SwiftPM 6.0 (CLT 16.x, as on the macOS 14 VM)
# hands multi-arch builds to xcbuild, which ships only with Xcode. Then the
# script builds each architecture on its own and joins them with lipo.
#
# Version: TANKARD_VERSION (default from the latest v* git tag, else 0.2.0).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=dist
SIGN=adhoc
ARCH_ARGS=()
UNIVERSAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) UNIVERSAL=1 ;;
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

LIPO_FROM=()
if [ $UNIVERSAL = 1 ]; then
    echo "==> swift build -c release --arch x86_64 --arch arm64"
    if swift build -c release --arch x86_64 --arch arm64 --product TankardApp; then
        BIN=$(swift build -c release --arch x86_64 --arch arm64 --show-bin-path)
    else
        echo "==> one multi-arch build isn't available here; building each architecture and joining them"
        for arch in x86_64 arm64; do
            swift build -c release --arch "$arch" --product TankardApp
            LIPO_FROM+=("$(swift build -c release --arch "$arch" --show-bin-path)/TankardApp")
        done
        BIN=$(swift build -c release --arch arm64 --show-bin-path) # resources are the same for both
    fi
else
    echo "==> swift build -c release ${ARCH_ARGS[*]:-}"
    swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product TankardApp
    BIN=$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)
fi

APP="$OUT/Tankard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ ${#LIPO_FROM[@]} -gt 0 ]; then
    lipo -create "${LIPO_FROM[@]}" -output "$APP/Contents/MacOS/Tankard"
else
    cp "$BIN/TankardApp" "$APP/Contents/MacOS/Tankard"
fi
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
