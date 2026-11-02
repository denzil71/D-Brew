#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) D-Brew.app into ./build.
# Usage: ./build.sh [--open] [--dmg]
#   --open  launch the app after building
#   --dmg   also package it as dist/D-Brew-<version>.dmg (unsigned)
set -euo pipefail
cd "$(dirname "$0")"

OPEN=0
DMG=0
for arg in "$@"; do
    case "$arg" in
        --open) OPEN=1 ;;
        --dmg) DMG=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# One build per architecture, then merged with lipo (a multi-arch `swift build` needs full Xcode).
BINS=()
for TRIPLE in arm64-apple-macosx13.0 x86_64-apple-macosx13.0; do
    swift build -c release --triple "$TRIPLE"
    BINS+=("$(swift build -c release --triple "$TRIPLE" --show-bin-path)/DBrew")
done

# Assembled and signed outside the project: in an iCloud-synced folder (e.g. ~/Documents) the
# File Provider keeps re-adding Finder info to the bundle, which codesign rejects.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SIGNED="$WORK/D-Brew.app"
mkdir -p "$SIGNED/Contents/MacOS" "$SIGNED/Contents/Resources"
lipo -create "${BINS[@]}" -output "$SIGNED/Contents/MacOS/DBrew"
cp Resources/Info.plist "$SIGNED/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$SIGNED/Contents/Resources/"
codesign --force --sign - "$SIGNED"

APP="build/D-Brew.app"
rm -rf "$APP"
mkdir -p build
ditto "$SIGNED" "$APP"
echo "Built $APP"

if (( DMG )); then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    DMG_PATH="dist/D-Brew-$VERSION.dmg"
    # Disk image with the app and an Applications shortcut to drag it onto.
    STAGE=$(mktemp -d)
    ditto "$SIGNED" "$STAGE/D-Brew.app"
    ln -s /Applications "$STAGE/Applications"
    mkdir -p dist
    hdiutil create -volname "D-Brew $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG_PATH" >/dev/null
    rm -rf "$STAGE"
    echo "Built $DMG_PATH"
fi

(( OPEN )) && open "$APP"
exit 0
