#!/bin/sh
set -eu
cd "$(dirname "$0")"
TARGET_ARCH=arm64 ./build.sh
VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
RELEASE_DIR="$PWD/build/release"
ARCHIVE="MZT-Player-$VERSION-macOS-arm64.zip"
mkdir -p "$RELEASE_DIR"
test "$(lipo -archs 'build/MZT Player.app/Contents/MacOS/MZTPlayer')" = arm64
cp 'build/MZT Player.zip' "$RELEASE_DIR/$ARCHIVE"
cd "$RELEASE_DIR"
shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt
printf 'Apple Silicon release: %s/%s\n' "$RELEASE_DIR" "$ARCHIVE"
