#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE_AGENTS_FILE="$ROOT/website/draft/.website-screenshot-live-agents"
FINAL_OUT_DIR="$ROOT/website/draft/assets"
USE_LIVE_AGENTS=0

while (($#)); do
  case "$1" in
    --live-agents)
      USE_LIVE_AGENTS=1
      shift
      ;;
    *)
      FINAL_OUT_DIR="$1"
      shift
      ;;
  esac
done

mkdir -p "$FINAL_OUT_DIR"
printf '%s\n' "$USE_LIVE_AGENTS" >"$LIVE_AGENTS_FILE"

cleanup() {
  rm -f "$LIVE_AGENTS_FILE"
}
trap cleanup EXIT

copy_attachments() {
  local result_bundle="$1"
  local attachments_dir="$2"

  xcrun xcresulttool export attachments \
    --path "$result_bundle" \
    --output-path "$attachments_dir" >/dev/null 2>&1 || true

  if [[ ! -f "$attachments_dir/manifest.json" ]]; then
    return
  fi

  python3 - "$attachments_dir" "$FINAL_OUT_DIR" <<'PY'
import json
import pathlib
import re
import shutil
import sys

attachments_dir = pathlib.Path(sys.argv[1])
final_dir = pathlib.Path(sys.argv[2])
manifest = json.loads((attachments_dir / "manifest.json").read_text())

for test_case in manifest:
    for attachment in test_case.get("attachments", []):
        exported_name = attachment.get("exportedFileName")
        suggested_name = attachment.get("suggestedHumanReadableName", "")
        if not exported_name or not suggested_name:
            continue
        source = attachments_dir / exported_name
        if not source.exists():
            continue
        if source.suffix.lower() != ".png":
            continue
        stem = pathlib.Path(suggested_name).stem
        stem = re.sub(r"_[0-9]+_[0-9A-F-]{36}$", "", stem)
        destination = final_dir / f"{stem}{source.suffix or '.png'}"
        shutil.copy2(source, destination)
PY
}

run_screenshot_test() {
  local test_identifier="$1"
  local result_bundle attachments_dir
  result_bundle="$(mktemp -d "${TMPDIR:-/tmp}/argon-website-result.XXXXXX").xcresult"
  attachments_dir="$(mktemp -d "${TMPDIR:-/tmp}/argon-website-attachments.XXXXXX")"

  if ! xcodebuild test \
    -project Argon.xcodeproj \
    -scheme ArgonUITests \
    -configuration Debug \
    -resultBundlePath "$result_bundle" \
    -only-testing:"$test_identifier"; then
    copy_attachments "$result_bundle" "$attachments_dir"
    printf '\nResult bundle preserved at %s\n' "$result_bundle" >&2
    printf 'Attachment export dir preserved at %s\n' "$attachments_dir" >&2
    return 1
  fi

  copy_attachments "$result_bundle" "$attachments_dir"
  rm -rf "$result_bundle" "$attachments_dir"
}

find "$FINAL_OUT_DIR" -maxdepth 1 -type f \( \
  -name 'workspace-window*.png' -o \
  -name 'feature-worktrees*.png' -o \
  -name 'feature-terminals*.png' -o \
  -name 'feature-review*.png' -o \
  -name 'review-window*.png' -o \
  -name 'review-agents*.png' -o \
  -name 'review-submit-sheet*.png' -o \
  -name 'UI Snapshot*.png' -o \
  -name 'Screen Recording*.mp4' -o \
  -name 'App UI hierarchy*.txt' -o \
  -name 'Debug description*.txt' -o \
  -regex '.*/[0-9A-F-]\{36\}\.png' \
\) -delete || true

cd "$ROOT/apps/macos"
xcodegen generate >/dev/null

tests=(
  "ArgonUITests/ArgonUITests/testCaptureWebsiteWorkspaceScreenshot"
  "ArgonUITests/ArgonUITests/testCaptureWebsiteFeatureWorktreesScreenshot"
  "ArgonUITests/ArgonUITests/testCaptureWebsiteFeatureTerminalsScreenshot"
  "ArgonUITests/ArgonUITests/testCaptureWebsiteFeatureReviewScreenshot"
  "ArgonUITests/ArgonUITests/testCaptureWebsiteReviewScreenshot"
  "ArgonUITests/ArgonUITests/testCaptureWebsiteReviewAgentsScreenshot"
)

for test_identifier in "${tests[@]}"; do
  run_screenshot_test "$test_identifier"
done
