#!/bin/sh
set -eu
cd "$(dirname "$0")"
BUILD="$PWD/build"
STAGING="$(mktemp -d /private/tmp/mzt-player-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/MZT Player.app"
mkdir -p "$BUILD/objects" "$BUILD/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"
case "$TARGET_ARCH" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$TARGET_ARCH" >&2; exit 1 ;; esac
for SOURCE in Encoder; do
    xcrun clang -isysroot "$SDK" -arch "$TARGET_ARCH" -mmacosx-version-min=13.0 -O2 -Wall -Wextra -Wno-unused-variable \
        -c "Sources/Encoder/$SOURCE.c" -o "$BUILD/objects/$SOURCE.o"
done
xcrun swiftc -sdk "$SDK" -swift-version 5 -target "$TARGET_ARCH-apple-macosx13.0" \
    -module-cache-path "$BUILD/module-cache" -O -parse-as-library \
    -import-objc-header Sources/Encoder/Encoder.h Sources/App/*.swift "$BUILD/objects/Encoder.o" \
    -framework SwiftUI -framework AppKit -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
    -o "$APP/Contents/MacOS/MZTPlayer"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp NOTICES.txt "$APP/Contents/Resources/"
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
# Archive before copying into a cloud-backed folder, which may attach Finder metadata.
ditto -c -k --keepParent --norsrc "$APP" "$BUILD/MZT Player.zip"
# Replace the old generated bundle so removed resources cannot survive a rebuild.
rm -rf "$BUILD/MZT Player.app"
ditto --noextattr "$APP" "$BUILD/MZT Player.app"
printf 'Built %s\n' "$BUILD/MZT Player.app"
