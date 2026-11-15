#!/bin/sh
# Explicit hardware integration check. Both output gains are zero throughout.
set -eu
cd "$(dirname "$0")/.."
test "$#" = 1 || { printf 'Usage: %s <non-default output UID>\n' "$0" >&2; exit 2; }
STAGING="$(mktemp -d /private/tmp/mzt-routing-test.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
xcrun clang -mmacosx-version-min=13.0 -c -O2 Sources/Encoder/Encoder.c -o "$STAGING/Encoder.o"
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" -swift-version 5 -module-cache-path "$STAGING/cache" \
    -import-objc-header Sources/Encoder/Encoder.h Sources/App/PlayerModel.swift \
    Sources/App/AudioDevices.swift Sources/App/AudioOutputRouting.swift \
    Sources/App/TapeHeader.swift Tests/AudioRoutingCheck.swift "$STAGING/Encoder.o" \
    -o "$STAGING/audio-routing-check"
"$STAGING/audio-routing-check" "$1"
