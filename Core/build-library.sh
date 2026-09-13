#!/bin/sh
# Fetches and builds the packaged engine library for all Apple platforms.
# The engine source location comes from the environment so this repository
# stays self-contained. Requires Go >= 1.21.
set -eu

: "${CORE_REPO_URL:?Set CORE_REPO_URL to the engine source repository URL}"
CORE_REF="${CORE_REF:-testing}"
CORE_DIR="${CORE_DIR:-$PWD/.core-src}"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_FRAMEWORK="$OUT_DIR/Libbox.xcframework"

# The forked toolchain is part of the engine's upstream project, so its module
# path also names the owner the engine's own modules live under.
GOMOBILE_MODULE="github.com/sagernet/gomobile"

export PATH="$HOME/go/bin:$PATH"

# git and go print remote URLs and module paths as they work, and this
# repository's CI logs are public, so the upstream identity would otherwise land
# in them verbatim — a clone failure echoes the URL straight back. Scrub the
# source location as git would show it, plus every module under the engine's
# upstream owner. Subpaths survive, so a compile error still names a readable
# package.
CORE_URL_ID="$(printf '%s' "$CORE_REPO_URL" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]*@##; s#\.git$##; s#/$##')"
CORE_URL_ID_ESC="$(printf '%s' "$CORE_URL_ID" | sed 's/\./\\./g; s/#/\\#/g')"
UPSTREAM_OWNER="${GOMOBILE_MODULE#github.com/}"
UPSTREAM_OWNER="${UPSTREAM_OWNER%%/*}"
UPSTREAM_OWNER_ESC="$(printf '%s' "$UPSTREAM_OWNER" | sed 's/\./\\./g')"

scrub() {
    sed -E \
        -e "s#${CORE_URL_ID_ESC}#<engine>#g" \
        -e "s#github\\.com/${UPSTREAM_OWNER_ESC}/[A-Za-z0-9_.-]+#<module>#g"
}

# pipefail keeps each step's own exit status across the scrub, which would
# otherwise report sed's status and let a failed build carry on.
set -o pipefail

step() {
    "$@" 2>&1 | scrub
}

if [ -d "$CORE_DIR" ]; then
    echo "Using existing checkout at $CORE_DIR"
else
    echo "Cloning engine source ($CORE_REF)..."
    step git clone --depth 1 --branch "$CORE_REF" "$CORE_REPO_URL" "$CORE_DIR"
fi

cd "$CORE_DIR"

echo "Installing the gomobile fork the engine build expects..."
step go install "$GOMOBILE_MODULE/cmd/gomobile@v0.1.13"
step go install "$GOMOBILE_MODULE/cmd/gobind@v0.1.13"
step gomobile init

echo "Building engine library (this takes a while)..."
step go run ./cmd/internal/build_libbox -target apple

BUILT="$(find . -maxdepth 3 -name 'Libbox.xcframework' -print -quit)"
if [ -z "$BUILT" ]; then
    echo "error: Libbox.xcframework not found after build" >&2
    exit 1
fi

rm -rf "$OUT_FRAMEWORK"
cp -R "$BUILT" "$OUT_FRAMEWORK"
echo "Installed: $OUT_FRAMEWORK"
echo "Next: drag $OUT_FRAMEWORK into both tunnel targets in Xcode (Frameworks build phase)."
