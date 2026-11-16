#!/bin/bash
# Rebuilds Resources/AppIcon.icns from the pixel-art logo
# (Sources/TankardApp/Resources/tankard-logo.png, 128x128).
#
#   Scripts/make-icon.sh [--keep DIR]    --keep: also leave the .iconset in DIR
#
# The .icns is committed, so building the app (and CI) doesn't run this; run
# it only when the logo or the plate changes. Needs ffmpeg (brew install
# ffmpeg) for the scaling, plus swiftc and iconutil from the Command Line Tools.
#
# The logo is only ever scaled with nearest neighbour (never redrawn or
# recoloured), then placed 1:1 on a plate drawn by Scripts/icon-compose.swift.
# Mug size per icon size, against the 128 px original:
#   1024: x6    512: x3    256: x1.5    128: x0.75    64: x0.375
#   32: 1/4     16: 1/8
# A nearest-neighbour shrink keeps one source pixel in every 4 (or 8), so
# which one it keeps decides whether the outline, handle and "i" survive. At
# 32 and 16 px the logo is shifted by a few source pixels first (the phase
# below), chosen by eye for legibility; the shift is under one output pixel.
set -euo pipefail
cd "$(dirname "$0")/.."

KEEP=
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=$2; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "make-icon.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

LOGO=Sources/TankardApp/Resources/tankard-logo.png
OUT=Resources/AppIcon.icns
command -v ffmpeg >/dev/null || { echo "make-icon.sh: needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc -O Scripts/icon-compose.swift -o "$WORK/icon-compose"

# render PX MUG_PX PHASE  -> $WORK/icon_PX.png
render() {
    local px=$1 mug=$2 phase=$3
    ffmpeg -v error -y -i "$LOGO" \
        -vf "format=rgba,pad=$((128 + phase)):$((128 + phase)):${phase}:${phase}:color=0x00000000,crop=128:128:0:0,scale=${mug}:${mug}:flags=neighbor" \
        "$WORK/mug_$px.png"
    "$WORK/icon-compose" "$px" "$WORK/mug_$px.png" "$WORK/icon_$px.png"
}
render 1024 768 0
render 512 384 0
render 256 192 0
render 128 96 0
render 64 48 0
render 32 32 3
render 16 16 2

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
cp "$WORK/icon_16.png" "$SET/icon_16x16.png"
cp "$WORK/icon_32.png" "$SET/icon_16x16@2x.png"
cp "$WORK/icon_32.png" "$SET/icon_32x32.png"
cp "$WORK/icon_64.png" "$SET/icon_32x32@2x.png"
cp "$WORK/icon_128.png" "$SET/icon_128x128.png"
cp "$WORK/icon_256.png" "$SET/icon_128x128@2x.png"
cp "$WORK/icon_256.png" "$SET/icon_256x256.png"
cp "$WORK/icon_512.png" "$SET/icon_256x256@2x.png"
cp "$WORK/icon_512.png" "$SET/icon_512x512.png"
cp "$WORK/icon_1024.png" "$SET/icon_512x512@2x.png"

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$SET" -o "$OUT"
if [ -n "$KEEP" ]; then
    mkdir -p "$KEEP"
    rm -rf "$KEEP/AppIcon.iconset"
    cp -R "$SET" "$KEEP/"
fi
echo "==> $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
