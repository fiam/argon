#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_TOOLS_DIR="$ROOT_DIR/.sparkle-tools"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.1}"
SPARKLE_ARCHIVE="Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_DOWNLOAD_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/${SPARKLE_ARCHIVE}"

if [[ -x "$SPARKLE_TOOLS_DIR/bin/generate_appcast" && -x "$SPARKLE_TOOLS_DIR/bin/sign_update" && -x "$SPARKLE_TOOLS_DIR/bin/generate_keys" ]]; then
  exit 0
fi

rm -rf "$SPARKLE_TOOLS_DIR"
mkdir -p "$SPARKLE_TOOLS_DIR"

curl -fsSL "$SPARKLE_DOWNLOAD_URL" -o "$SPARKLE_TOOLS_DIR/$SPARKLE_ARCHIVE"

tar -xf \
  "$SPARKLE_TOOLS_DIR/$SPARKLE_ARCHIVE" \
  -C "$SPARKLE_TOOLS_DIR" \
  --strip-components=1
