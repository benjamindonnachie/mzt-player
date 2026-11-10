#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /private/tmp/mzt-player-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
    -ISources/Encoder Sources/Encoder/Encoder.c Tests/sanitise.c -o "$TEST_DIR/sanitise"
"$TEST_DIR/sanitise"
printf 'AddressSanitizer and UndefinedBehaviorSanitizer checks passed.\n'
