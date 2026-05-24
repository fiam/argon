#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

function fail() {
  echo "release metadata check failed: $*" >&2
  exit 1
}

function read_required_version() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    fail "could not read $label"
  fi
  printf '%s' "$value"
}

function require_matching_version() {
  local label="$1"
  local value="$2"
  if [[ "$value" != "$VERSION" ]]; then
    fail "$label is $value, expected $VERSION"
  fi
}

VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/version.txt")"
VERSION="$(read_required_version version.txt "$VERSION")"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
  fail "version.txt must contain a semantic version like 0.4.0"
fi

CARGO_VERSION="$(
  awk '
    /^\[workspace\.package\]$/ { in_workspace_package = 1; next }
    /^\[/ { in_workspace_package = 0 }
    in_workspace_package && $1 == "version" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$ROOT_DIR/Cargo.toml"
)"
CARGO_VERSION="$(read_required_version "Cargo.toml workspace.package.version" "$CARGO_VERSION")"

XCODE_VERSION="$(
  sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*/\1/p' \
    "$ROOT_DIR/apps/macos/project.yml" | head -n 1
)"
XCODE_VERSION="$(read_required_version "apps/macos/project.yml MARKETING_VERSION" "$XCODE_VERSION")"

RELEASE_PLEASE_VERSION="$(
  sed -nE 's/^[[:space:]]*"\.":[[:space:]]*"([^"]+)".*/\1/p' \
    "$ROOT_DIR/.release-please-manifest.json" | head -n 1
)"
RELEASE_PLEASE_VERSION="$(
  read_required_version ".release-please-manifest.json package version" \
    "$RELEASE_PLEASE_VERSION"
)"

require_matching_version "Cargo.toml workspace.package.version" "$CARGO_VERSION"
require_matching_version "apps/macos/project.yml MARKETING_VERSION" "$XCODE_VERSION"
require_matching_version ".release-please-manifest.json package version" "$RELEASE_PLEASE_VERSION"

grep -Eq '"version-file"[[:space:]]*:[[:space:]]*"version.txt"' \
  "$ROOT_DIR/release-please-config.json" \
  || fail "release-please-config.json must use version.txt as the version file"
grep -Eq '"path"[[:space:]]*:[[:space:]]*"Cargo.toml"' \
  "$ROOT_DIR/release-please-config.json" \
  || fail "release-please-config.json must update Cargo.toml"
grep -Eq '"path"[[:space:]]*:[[:space:]]*"apps/macos/project.yml"' \
  "$ROOT_DIR/release-please-config.json" \
  || fail "release-please-config.json must update apps/macos/project.yml"

echo "release metadata is consistent for $VERSION"
