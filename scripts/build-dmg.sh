#!/usr/bin/env bash

set -euo pipefail

APP_PATH=""
OUTPUT_PATH=""
VOLUME_NAME="${ARGON_DMG_VOLUME_NAME:-Argon}"
STAGING=""

function cleanup() {
  if [[ -n "$STAGING" && -d "$STAGING" ]]; then
    rm -rf "$STAGING"
  fi
}

trap cleanup EXIT

function usage() {
  cat <<EOF >&2
usage: $0 --app /path/to/Argon.app --output /path/to/Argon.dmg [--volume-name NAME]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    --volume-name)
      VOLUME_NAME="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$OUTPUT_PATH" ]]; then
  usage
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "app not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/argon-dmg-staging.XXXXXX")"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUTPUT_PATH"
