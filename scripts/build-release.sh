#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
VERSION=$(grep 'MARKETING_VERSION' "$REPO_ROOT/apps/macos/project.yml" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
CREATE_DMG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg) CREATE_DMG=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

echo "==> Building Argon $VERSION (release)"

# 1. Build the Rust CLI
echo "==> Building argon CLI..."
cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin argon --release 2>&1

# 2. Build vendored Ghostty in release mode
echo "==> Building vendored libghostty..."
bash "$REPO_ROOT/scripts/build-libghostty.sh" --release

# 3. Generate Xcode project
echo "==> Generating Xcode project..."
(cd "$REPO_ROOT/apps/macos" && xcodegen generate 2>&1)

# 4. Build the app in Release
echo "==> Building Argon.app (Release)..."
xcodebuild \
    -project "$REPO_ROOT/apps/macos/Argon.xcodeproj" \
    -scheme Argon \
    -configuration Release \
    ENABLE_HARDENED_RUNTIME=YES \
    build 2>&1 | tail -1

# 5. Find the built app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Argon-*/Build/Products/Release -name "Argon.app" -type d 2>/dev/null | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "error: Argon.app not found in DerivedData" >&2
    exit 1
fi

# 6. Bundle the CLI binary inside the app
echo "==> Bundling CLI into app..."
mkdir -p "$APP_PATH/Contents/Resources/bin"
cp "$REPO_ROOT/target/release/argon" "$APP_PATH/Contents/Resources/bin/argon"

# 7. Copy to build output
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/Argon.app"
cp -R "$APP_PATH" "$BUILD_DIR/Argon.app"
echo "==> Built: $BUILD_DIR/Argon.app"

# 8. Optionally create DMG
if $CREATE_DMG; then
    DMG_NAME="Argon-${VERSION}.dmg"
    DMG_PATH="$BUILD_DIR/$DMG_NAME"
    rm -f "$DMG_PATH"

    echo "==> Creating $DMG_NAME..."
    STAGING="$BUILD_DIR/dmg-staging"
    rm -rf "$STAGING"
    mkdir -p "$STAGING"
    cp -R "$BUILD_DIR/Argon.app" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"

    hdiutil create \
        -volname "Argon" \
        -srcfolder "$STAGING" \
        -ov \
        -format UDZO \
        "$DMG_PATH" 2>&1

    rm -rf "$STAGING"
    echo "==> Created: $DMG_PATH"
fi

echo "==> Done!"
