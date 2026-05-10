#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_REPO="${1:-.}"

# Resolve target to absolute path
if [[ "$TARGET_REPO" != /* ]]; then
    TARGET_REPO="$(cd "$TARGET_REPO" && pwd)"
fi
TARGET_WORKTREE="$(git -C "$TARGET_REPO" rev-parse --show-toplevel)"
TARGET_COMMON_DIR="$(git -C "$TARGET_REPO" rev-parse --path-format=absolute --git-common-dir)"
if [[ "$(basename "$TARGET_COMMON_DIR")" == ".git" ]]; then
    TARGET_REPO_ROOT="$(dirname "$TARGET_COMMON_DIR")"
else
    TARGET_REPO_ROOT="$TARGET_WORKTREE"
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

DERIVED_DATA_PATH="$REPO_ROOT/target/xcode-derived-data"

echo "==> Building Argon.app..."
xcodebuild \
    -project "$REPO_ROOT/apps/macos/Argon.xcodeproj" \
    -scheme Argon \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build 2>&1

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Argon.app"
if [[ ! -x "$APP_PATH/Contents/MacOS/Argon" ]]; then
    echo "error: runnable Argon.app not found at $APP_PATH" >&2
    exit 1
fi

all_running_argon_pids() {
    local pids=""

    if command -v osascript >/dev/null 2>&1; then
        pids="$(
            osascript \
                -e 'tell application "System Events" to get unix id of every process whose bundle identifier is "dev.argonapp.macos"' \
                2>/dev/null \
                | tr ',' '\n' \
                | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                | grep -E '^[0-9]+$' \
                || true
        )"
    fi

    if [[ -z "$pids" ]]; then
        pids="$(pgrep -f "$APP_PATH/Contents/MacOS/Argon" 2>/dev/null || true)"
    fi

    printf '%s\n' "$pids" | awk 'NF && !seen[$0]++'
}

target_argon_pids() {
    local pid command
    while IFS= read -r pid; do
        if [[ -z "$pid" ]]; then
            continue
        fi

        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command" == *"--selected-worktree-path $TARGET_WORKTREE" ]]; then
            echo "$pid"
        fi
    done < <(all_running_argon_pids)
}

pids_are_running() {
    local pid
    for pid in "$@"; do
        if kill -0 "$pid" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

quit_argon_pid() {
    local pid="$1"
    if command -v osascript >/dev/null 2>&1; then
        osascript \
            -e "tell application \"System Events\" to tell (first application process whose unix id is $pid) to quit" \
            >/dev/null 2>&1 \
            && return
    fi

    kill "$pid" 2>/dev/null || true
}

wait_for_pids_to_exit() {
    local -a pids=("$@")
    for _ in {1..50}; do
        if ! pids_are_running "${pids[@]}"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

quit_running_argon() {
    local -a pids=()
    local pid
    while IFS= read -r pid; do
        if [[ -n "$pid" ]]; then
            pids+=("$pid")
        fi
    done < <(target_argon_pids)
    if [[ "${#pids[@]}" -eq 0 ]]; then
        return
    fi

    echo "==> Quitting Argon for $TARGET_WORKTREE (${pids[*]})..."
    for pid in "${pids[@]}"; do
        quit_argon_pid "$pid"
    done

    if wait_for_pids_to_exit "${pids[@]}"; then
        return
    fi

    echo "==> Force stopping unresponsive Argon..."
    kill "${pids[@]}" 2>/dev/null || true
    wait_for_pids_to_exit "${pids[@]}" || true
}

quit_running_argon

launch_args=(
    --workspace-repo-root "$TARGET_REPO_ROOT"
    --workspace-common-dir "$TARGET_COMMON_DIR"
    --selected-worktree-path "$TARGET_WORKTREE"
)

echo "==> Launching workspace for $TARGET_REPO"
echo "workspace: $TARGET_REPO_ROOT"
echo "common-dir: $TARGET_COMMON_DIR"
echo "selected-worktree: $TARGET_WORKTREE"

if [[ -n "${ARGON_FORCE_CLI_INSTALL_TOAST:-}" ]]; then
    echo "==> Running Argon in the foreground"
    "$APP_PATH/Contents/MacOS/Argon" "${launch_args[@]}"
    exit $?
fi

open -n -a "$APP_PATH" --args "${launch_args[@]}"

for _ in {1..50}; do
    launched_pids=()
    while IFS= read -r pid; do
        if [[ -n "$pid" ]]; then
            launched_pids+=("$pid")
        fi
    done < <(target_argon_pids)
    if [[ "${#launched_pids[@]}" -gt 0 ]]; then
        echo "==> Running Argon (${launched_pids[*]})"
        break
    fi
    sleep 0.1
done
