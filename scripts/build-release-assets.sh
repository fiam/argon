#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
RELEASE_TAG="${ARGON_RELEASE_TAG:-v$VERSION}"
REPOSITORY="${ARGON_REPOSITORY:-fiam/argon}"
DOWNLOAD_URL_PREFIX="${ARGON_DOWNLOAD_URL_PREFIX:-https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG}"
BUILD_NUMBER="${ARGON_BUILD_NUMBER:-1}"
APPCAST_FEED_URL="${ARGON_APPCAST_FEED_URL:-https://argonapp.dev/appcast.xml}"
APPCAST_LINK_URL="${ARGON_APPCAST_LINK_URL:-https://argonapp.dev}"

DERIVED_DATA_PATH="$ROOT_DIR/.derived-release"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_CACHE_PATH="$DERIVED_DATA_PATH/PackageCache"
CLONED_SOURCE_PACKAGES_PATH="$DERIVED_DATA_PATH/SourcePackages"
ARCHIVE_PATH="$DERIVED_DATA_PATH/Argon.xcarchive"
EXPORT_PATH="$DERIVED_DATA_PATH/export"
EXPORT_OPTIONS_PATH="$DERIVED_DATA_PATH/ExportOptions.plist"
GHOSTTY_NATIVE_ROOT="$ROOT_DIR/target/libghostty/native"
GHOSTTY_UNIVERSAL_ROOT="$ROOT_DIR/target/libghostty/universal"
GHOSTTY_UNIVERSAL_STATIC_LIB="$GHOSTTY_NATIVE_ROOT/macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a"
GHOSTTY_NATIVE_BACKUP="$DERIVED_DATA_PATH/ghostty-native-backup"
UNIVERSAL_CLI_DIR="$DERIVED_DATA_PATH/universal-cli"
UNIVERSAL_CLI_PATH="$UNIVERSAL_CLI_DIR/argon"
APP_PATH=""
RELEASE_BUNDLE_IDENTIFIER=""
APPCAST_DIR="$DIST_DIR/appcast"
SPARKLE_TOOLS_DIR="$ROOT_DIR/.sparkle-tools"
VERSIONED_ZIP_NAME="Argon-${VERSION}.zip"
VERSIONED_DMG_NAME="Argon-${VERSION}.dmg"
STABLE_ZIP_NAME="Argon.zip"
STABLE_DMG_NAME="Argon.dmg"
NOTARY_SUBMISSION_ZIP_NAME=".Argon-notary-submit.zip"
CASK_NAME="argon.rb"
APPCAST_NAME="appcast.xml"

SIGNED_RELEASE=false
NOTARIZED_RELEASE=false
SPARKLE_APPCAST=false

function require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      echo "missing required environment variable: $name" >&2
      exit 1
    fi
  done
}

function notarize() {
  local path="$1"
  local output_path
  local submission_id
  local status

  output_path="$DIST_DIR/.notary-$(basename "$path").json"

  xcrun notarytool submit "$path" \
    --key "$ARGON_NOTARY_KEY_FILE" \
    --key-id "$ARGON_NOTARY_KEY_ID" \
    --issuer "$ARGON_NOTARY_ISSUER_ID" \
    --wait \
    --output-format json >"$output_path"

  submission_id="$(
    python3 - "$output_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)

print(payload["id"])
PY
  )"

  status="$(
    python3 - "$output_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)

print(payload["status"])
PY
  )"

  if [[ "$status" != "Accepted" ]]; then
    echo "notarization failed for $(basename "$path") with status: $status" >&2
    xcrun notarytool log "$submission_id" \
      --key "$ARGON_NOTARY_KEY_FILE" \
      --key-id "$ARGON_NOTARY_KEY_ID" \
      --issuer "$ARGON_NOTARY_ISSUER_ID" >&2 || true
    return 1
  fi
}

function require_arches() {
  local binary_path="$1"
  local actual_arches
  actual_arches="$(lipo -archs "$binary_path")"
  for expected_arch in arm64 x86_64; do
    if [[ " $actual_arches " != *" $expected_arch "* ]]; then
      echo "missing expected architecture slice: $expected_arch in $binary_path" >&2
      echo "found architectures: $actual_arches" >&2
      exit 1
    fi
  done
}

function require_hardened_runtime() {
  local signed_path="$1"
  local signature_details

  signature_details="$(codesign --display --verbose=4 "$signed_path" 2>&1)"
  if [[ "$signature_details" != *"Runtime Version="* && "$signature_details" != *"flags="*"runtime"* ]]; then
    echo "hardened runtime is not enabled for $signed_path" >&2
    echo "$signature_details" >&2
    exit 1
  fi
}

function restore_native_ghostty_layout() {
  if [[ -L "$GHOSTTY_NATIVE_ROOT" ]]; then
    rm -f "$GHOSTTY_NATIVE_ROOT"
  elif [[ -d "$GHOSTTY_NATIVE_ROOT" && -d "$GHOSTTY_NATIVE_BACKUP" ]]; then
    rm -rf "$GHOSTTY_NATIVE_ROOT"
  fi

  if [[ -d "$GHOSTTY_NATIVE_BACKUP" ]]; then
    mv "$GHOSTTY_NATIVE_BACKUP" "$GHOSTTY_NATIVE_ROOT"
  fi
}

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "version must be a macOS marketing version like 0.1.0" >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "build number must be an integer" >&2
  exit 1
fi

if [[ -n "${ARGON_CODESIGN_IDENTITY:-}" || -n "${ARGON_APPLE_TEAM_ID:-}" ]]; then
  require_env ARGON_CODESIGN_IDENTITY ARGON_APPLE_TEAM_ID
  SIGNED_RELEASE=true
fi

if [[ -n "${ARGON_NOTARY_KEY_FILE:-}" || -n "${ARGON_NOTARY_KEY_ID:-}" || -n "${ARGON_NOTARY_ISSUER_ID:-}" ]]; then
  require_env ARGON_NOTARY_KEY_FILE ARGON_NOTARY_KEY_ID ARGON_NOTARY_ISSUER_ID
  NOTARIZED_RELEASE=true
fi

if [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
  require_env SPARKLE_PUBLIC_ED_KEY
  SPARKLE_APPCAST=true
  "$ROOT_DIR/scripts/setup-sparkle-tools.sh"
fi

rm -rf "$DERIVED_DATA_PATH" "$DIST_DIR"
mkdir -p "$DIST_DIR" "$PACKAGE_CACHE_PATH" "$CLONED_SOURCE_PACKAGES_PATH" "$UNIVERSAL_CLI_DIR"
trap restore_native_ghostty_layout EXIT

pushd "$ROOT_DIR" >/dev/null

if command -v rustup >/dev/null 2>&1; then
  rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
fi

export RUSTFLAGS="${RUSTFLAGS:--Dwarnings}"

cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --bin argon --release --target aarch64-apple-darwin
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --bin argon --release --target x86_64-apple-darwin

lipo -create \
  -output "$UNIVERSAL_CLI_PATH" \
  "$ROOT_DIR/target/aarch64-apple-darwin/release/argon" \
  "$ROOT_DIR/target/x86_64-apple-darwin/release/argon"

chmod +x "$UNIVERSAL_CLI_PATH"
require_arches "$UNIVERSAL_CLI_PATH"

bash "$ROOT_DIR/scripts/build-libghostty.sh" --target universal --release

rm -rf "$GHOSTTY_NATIVE_BACKUP"
if [[ -e "$GHOSTTY_NATIVE_ROOT" || -L "$GHOSTTY_NATIVE_ROOT" ]]; then
  mv "$GHOSTTY_NATIVE_ROOT" "$GHOSTTY_NATIVE_BACKUP"
fi
ln -s "$GHOSTTY_UNIVERSAL_ROOT" "$GHOSTTY_NATIVE_ROOT"

if [[ ! -f "$GHOSTTY_UNIVERSAL_STATIC_LIB" ]]; then
  echo "expected universal libghostty not found at $GHOSTTY_UNIVERSAL_STATIC_LIB" >&2
  exit 1
fi

(cd "$ROOT_DIR/apps/macos" && xcodegen generate)

export ARGON_SKIP_BUNDLED_CLI_BUILD=1
export ARGON_BUNDLED_CLI_PATH="$UNIVERSAL_CLI_PATH"

if [[ "$SPARKLE_APPCAST" != "true" ]]; then
  export ARGON_APPCAST_FEED_URL=""
  export SPARKLE_PUBLIC_ED_KEY=""
else
  export ARGON_APPCAST_FEED_URL="$APPCAST_FEED_URL"
fi

xcodebuild_args=(
  -project "$ROOT_DIR/apps/macos/Argon.xcodeproj"
  -scheme Argon
  -configuration Release
  -derivedDataPath "$DERIVED_DATA_PATH"
  -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_PATH"
  -packageCachePath "$PACKAGE_CACHE_PATH"
  -destination "generic/platform=macOS"
  ONLY_ACTIVE_ARCH=NO
  ARCHS="arm64 x86_64"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  ENABLE_HARDENED_RUNTIME=YES
  ARGON_GHOSTTY_STATIC_LIB="$GHOSTTY_UNIVERSAL_STATIC_LIB"
  ARGON_APPCAST_FEED_URL="${ARGON_APPCAST_FEED_URL:-}"
  SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
)

if [[ "$SIGNED_RELEASE" == "true" ]]; then
  xcodebuild_args+=(
    DEVELOPMENT_TEAM="$ARGON_APPLE_TEAM_ID"
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$ARGON_CODESIGN_IDENTITY"
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )

  cat >"$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>$ARGON_APPLE_TEAM_ID</string>
</dict>
</plist>
EOF

  xcodebuild "${xcodebuild_args[@]}" \
    -archivePath "$ARCHIVE_PATH" \
    archive

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

  APP_PATH="$EXPORT_PATH/Argon.app"
else
  xcodebuild "${xcodebuild_args[@]}" CODE_SIGNING_ALLOWED=NO build
  APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Argon.app"
fi

APP_EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/Argon"
BUNDLED_CLI_PATH="$APP_PATH/Contents/Resources/bin/argon"

if [[ ! -d "$APP_PATH" ]]; then
  echo "expected app not found at $APP_PATH" >&2
  exit 1
fi

RELEASE_BUNDLE_IDENTIFIER="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist"
)"

if [[ -z "$RELEASE_BUNDLE_IDENTIFIER" ]]; then
  echo "built app is missing CFBundleIdentifier" >&2
  exit 1
fi

require_arches "$APP_EXECUTABLE_PATH"
require_arches "$BUNDLED_CLI_PATH"

if [[ "$SIGNED_RELEASE" == "true" ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  require_hardened_runtime "$APP_PATH"
fi

if [[ "$NOTARIZED_RELEASE" == "true" ]]; then
  ditto -c -k --sequesterRsrc --keepParent \
    "$APP_PATH" \
    "$DIST_DIR/$NOTARY_SUBMISSION_ZIP_NAME"
  notarize "$DIST_DIR/$NOTARY_SUBMISSION_ZIP_NAME"
  xcrun stapler staple "$APP_PATH"
  rm -f "$DIST_DIR/$NOTARY_SUBMISSION_ZIP_NAME"
fi

cp -R "$APP_PATH" "$DIST_DIR/Argon.app"

ditto -c -k --sequesterRsrc --keepParent \
  "$APP_PATH" \
  "$DIST_DIR/$VERSIONED_ZIP_NAME"

"$ROOT_DIR/scripts/build-dmg.sh" \
  --app "$APP_PATH" \
  --output "$DIST_DIR/$VERSIONED_DMG_NAME" \
  --volume-name "Argon"

if [[ "$NOTARIZED_RELEASE" == "true" ]]; then
  notarize "$DIST_DIR/$VERSIONED_DMG_NAME"
  xcrun stapler staple "$DIST_DIR/$VERSIONED_DMG_NAME"
fi

cp "$DIST_DIR/$VERSIONED_ZIP_NAME" "$DIST_DIR/$STABLE_ZIP_NAME"
cp "$DIST_DIR/$VERSIONED_DMG_NAME" "$DIST_DIR/$STABLE_DMG_NAME"

if [[ "$SPARKLE_APPCAST" == "true" ]]; then
  rm -rf "$APPCAST_DIR"
  mkdir -p "$APPCAST_DIR"
  cp "$DIST_DIR/$VERSIONED_ZIP_NAME" "$APPCAST_DIR/"

  printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | \
    "$SPARKLE_TOOLS_DIR/bin/generate_appcast" \
      --ed-key-file - \
      --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
      --link "$APPCAST_LINK_URL" \
      -o "$DIST_DIR/$APPCAST_NAME" \
      "$APPCAST_DIR"
fi

DMG_SHA256="$(shasum -a 256 "$DIST_DIR/$VERSIONED_DMG_NAME" | awk '{print $1}')"
ARGON_HOMEBREW_CASK_VERSION="$VERSION" \
ARGON_HOMEBREW_CASK_SHA256="$DMG_SHA256" \
ARGON_HOMEBREW_CASK_URL="$DOWNLOAD_URL_PREFIX/$VERSIONED_DMG_NAME" \
ARGON_HOMEBREW_CASK_BUNDLE_ID="$RELEASE_BUNDLE_IDENTIFIER" \
  "$ROOT_DIR/scripts/generate-homebrew-cask.sh" > "$DIST_DIR/$CASK_NAME"

checksum_inputs=(
  "$VERSIONED_ZIP_NAME"
  "$VERSIONED_DMG_NAME"
  "$STABLE_ZIP_NAME"
  "$STABLE_DMG_NAME"
  "$CASK_NAME"
)

if [[ -f "$DIST_DIR/$APPCAST_NAME" ]]; then
  checksum_inputs+=("$APPCAST_NAME")
fi

(
  cd "$DIST_DIR"
  shasum -a 256 "${checksum_inputs[@]}" > checksums.txt
)

cat > "$DIST_DIR/release-metadata.json" <<EOF
{
  "version": "$VERSION",
  "buildNumber": "$BUILD_NUMBER",
  "tag": "$RELEASE_TAG",
  "repository": "$REPOSITORY",
  "bundleIdentifier": "$RELEASE_BUNDLE_IDENTIFIER",
  "architectures": "arm64 x86_64",
  "signed": $SIGNED_RELEASE,
  "notarized": $NOTARIZED_RELEASE,
  "zip": "$VERSIONED_ZIP_NAME",
  "dmg": "$VERSIONED_DMG_NAME",
  "stableZip": "$STABLE_ZIP_NAME",
  "stableDmg": "$STABLE_DMG_NAME",
  "homebrewCask": "$CASK_NAME",
  "downloadURLPrefix": "$DOWNLOAD_URL_PREFIX",
  "appcast": $( [[ -f "$DIST_DIR/$APPCAST_NAME" ]] && printf '"%s"' "$APPCAST_NAME" || printf 'null' )
}
EOF

rm -rf "$APPCAST_DIR"

popd >/dev/null
