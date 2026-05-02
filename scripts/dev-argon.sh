#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_REPO="${1:-.}"

# Resolve target to absolute path
if [[ "$TARGET_REPO" != /* ]]; then
    TARGET_REPO="$(cd "$TARGET_REPO" && pwd)"
fi

echo "==> Building argon CLI..."
cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin argon --release 2>&1

GHOSTTY_XCFRAMEWORK="$REPO_ROOT/target/libghostty/native/macos/GhosttyKit.xcframework"
GHOSTTY_RESOURCES="$REPO_ROOT/target/libghostty/native/share/ghostty"
if [[ ! -d "$GHOSTTY_XCFRAMEWORK" || ! -d "$GHOSTTY_RESOURCES" ]]; then
    echo "==> Building vendored libghostty..."
    bash "$REPO_ROOT/scripts/build-libghostty.sh"
fi

echo "==> Generating Xcode project..."
(cd "$REPO_ROOT/apps/macos" && xcodegen generate 2>&1)

echo "==> Building Argon.app..."
xcodebuild \
    -project "$REPO_ROOT/apps/macos/Argon.xcodeproj" \
    -scheme Argon \
    -configuration Debug \
    build 2>&1

# Find the built app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Argon-*/Build/Products/Debug -name "Argon.app" -type d 2>/dev/null | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "error: Argon.app not found in DerivedData" >&2
    exit 1
fi

quit_running_argon() {
    if ! pgrep -x Argon >/dev/null 2>&1; then
        return
    fi

    echo "==> Quitting running Argon..."
    osascript -e 'tell application id "dev.argonapp.macos" to quit' >/dev/null 2>&1 &

    for _ in {1..50}; do
        if ! pgrep -x Argon >/dev/null 2>&1; then
            return
        fi
        sleep 0.1
    done

    echo "==> Force stopping unresponsive Argon..."
    pkill -x Argon 2>/dev/null || true
    for _ in {1..20}; do
        if ! pgrep -x Argon >/dev/null 2>&1; then
            return
        fi
        sleep 0.1
    done
}

quit_running_argon

echo "==> Launching workspace for $TARGET_REPO"
ARGON_APP="$APP_PATH" "$REPO_ROOT/target/release/argon" \
    "$TARGET_REPO"
