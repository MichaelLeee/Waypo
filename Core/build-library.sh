#!/bin/sh
# Fetches and builds the packaged engine library for all Apple platforms.
# The engine source location comes from the environment so this repository
# stays self-contained. Requires Go >= 1.21 with gomobile installed
# (go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init).
set -eu

: "${CORE_REPO_URL:?Set CORE_REPO_URL to the engine source repository URL}"
CORE_REF="${CORE_REF:-testing}"
CORE_DIR="${CORE_DIR:-$PWD/.core-src}"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_FRAMEWORK="$OUT_DIR/Libbox.xcframework"

if [ -d "$CORE_DIR" ]; then
    echo "Using existing checkout at $CORE_DIR"
else
    echo "Cloning engine source ($CORE_REF)..."
    git clone --depth 1 --branch "$CORE_REF" "$CORE_REPO_URL" "$CORE_DIR"
fi

cd "$CORE_DIR"
echo "Building engine library (this takes a while)..."
make libbox

BUILT="$(find . -maxdepth 2 -name 'libbox.xcframework' | head -n 1)"
if [ -z "$BUILT" ]; then
    echo "error: libbox.xcframework not found after build" >&2
    exit 1
fi

rm -rf "$OUT_FRAMEWORK"
cp -R "$BUILT" "$OUT_FRAMEWORK"
echo "Installed: $OUT_FRAMEWORK"
echo "Next: drag $OUT_FRAMEWORK into both tunnel targets in Xcode (Frameworks build phase)."
