#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="${ARGON_REPOSITORY:-fiam/argon}"
VERSION="${ARGON_HOMEBREW_CASK_VERSION:-}"
SHA256="${ARGON_HOMEBREW_CASK_SHA256:-}"
DOWNLOAD_URL="${ARGON_HOMEBREW_CASK_URL:-}"
BUNDLE_ID="${ARGON_HOMEBREW_CASK_BUNDLE_ID:-dev.argonapp.macos}"
HOMEPAGE="${ARGON_HOMEBREW_CASK_HOMEPAGE:-https://argonapp.dev}"

if [[ -z "$VERSION" || -z "$SHA256" || -z "$DOWNLOAD_URL" ]]; then
  echo "cask generation requires version, sha256, and download URL" >&2
  exit 1
fi

VERSION_LINE="  version \"$VERSION\""
SHA256_LINE="  sha256 \"$SHA256\""

cat <<EOF
cask "argon" do
${VERSION_LINE}
${SHA256_LINE}

  url "${DOWNLOAD_URL}",
      verified: "github.com/${REPOSITORY}/"
  name "Argon"
  desc "Native macOS workspace for coding agents"
  homepage "${HOMEPAGE}"

  auto_updates true

  app "Argon.app"

  zap trash: [
    "~/Library/Application Support/Argon",
    "~/Library/Caches/${BUNDLE_ID}",
    "~/Library/HTTPStorages/${BUNDLE_ID}",
    "~/Library/Preferences/${BUNDLE_ID}.plist",
    "~/Library/Saved Application State/${BUNDLE_ID}.savedState"
  ]
end
EOF
