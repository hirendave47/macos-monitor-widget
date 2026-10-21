#!/usr/bin/env bash
#
# Builds System Rings (a macOS desktop widget app) from main.swift.
# Output: build/SystemRings.app  — launch it with `open build/SystemRings.app`
#
# Requires: Xcode Command Line Tools (xcode-select --install)
#
set -euo pipefail
cd "$(dirname "$0")"

EXEC_NAME="SystemRings"
APP_DIR="build/SystemRings.app"

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

echo "Compiling ($ARCH, min macOS 13)…"
swiftc -O \
    -target "${ARCH}-apple-macos13.0" \
    main.swift \
    -o "$APP_DIR/Contents/MacOS/${EXEC_NAME}"

cp Info.plist "$APP_DIR/Contents/Info.plist"

codesign --force --sign - "$APP_DIR"

echo
echo "Built: $PWD/$APP_DIR"
echo "Run:   open \"$PWD/$APP_DIR\""
