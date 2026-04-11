#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build the vendored Ghostty xcframework for Argon.

Usage:
  bash scripts/build-libghostty.sh [options]

Options:
  --target <native|universal>  Build target. Default: native
  --release                    Build with -Doptimize=ReleaseFast
  --debug                      Build with -Doptimize=Debug
  --output-dir <path>          Install root. Default: target/libghostty
  --clean                      Remove the target install directory first
  --print-path                 Print the xcframework path and exit
  --print-resources-path       Print the Ghostty resources path and exit
  --help                       Show this help
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GHOSTTY_DIR="${REPO_ROOT}/third_party/ghostty"

TARGET="native"
OPTIMIZE="Debug"
OUTPUT_ROOT="${REPO_ROOT}/target/libghostty"
CLEAN=0
PRINT_PATH=0
PRINT_RESOURCES_PATH=0
STAGING_ROOT="${GHOSTTY_DIR}/zig-out"
UPSTREAM_XCFRAMEWORK_PATH="${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      if [[ $# -lt 2 ]]; then
        echo "error: --target requires a value" >&2
        exit 1
      fi
      TARGET="$2"
      shift 2
      ;;
    --release)
      OPTIMIZE="ReleaseFast"
      shift
      ;;
    --debug)
      OPTIMIZE="Debug"
      shift
      ;;
    --output-dir)
      if [[ $# -lt 2 ]]; then
        echo "error: --output-dir requires a value" >&2
        exit 1
      fi
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --print-path)
      PRINT_PATH=1
      shift
      ;;
    --print-resources-path)
      PRINT_RESOURCES_PATH=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "${TARGET}" in
  native|universal) ;;
  *)
    echo "error: --target must be 'native' or 'universal'" >&2
    exit 1
    ;;
esac

INSTALL_ROOT="${OUTPUT_ROOT}/${TARGET}"
XCFRAMEWORK_PATH="${INSTALL_ROOT}/macos/GhosttyKit.xcframework"
RESOURCES_PATH="${INSTALL_ROOT}/share/ghostty"

if [[ ${PRINT_PATH} -eq 1 ]]; then
  printf '%s\n' "${XCFRAMEWORK_PATH}"
  exit 0
fi

if [[ ${PRINT_RESOURCES_PATH} -eq 1 ]]; then
  printf '%s\n' "${RESOURCES_PATH}"
  exit 0
fi

if [[ ! -f "${GHOSTTY_DIR}/build.zig" ]]; then
  echo "error: vendored Ghostty source not found at ${GHOSTTY_DIR}" >&2
  echo "hint: run 'git submodule update --init --recursive third_party/ghostty'" >&2
  exit 1
fi

if [[ ! -d "${GHOSTTY_DIR}/.git" && ! -f "${REPO_ROOT}/.git/modules/third_party/ghostty/HEAD" ]]; then
  echo "error: third_party/ghostty is present but the submodule is not initialized" >&2
  echo "hint: run 'git submodule update --init --recursive third_party/ghostty'" >&2
  exit 1
fi

if [[ -n "${ZIG:-}" && -x "${ZIG}" ]]; then
  ZIG_BIN="${ZIG}"
elif command -v zig >/dev/null 2>&1; then
  ZIG_BIN="$(command -v zig)"
else
  echo "error: zig not found. Install Zig or set ZIG to an absolute path." >&2
  exit 1
fi

if [[ -n "${XCODEBUILD:-}" && -x "${XCODEBUILD}" ]]; then
  XCODEBUILD_BIN="${XCODEBUILD}"
elif command -v xcodebuild >/dev/null 2>&1; then
  XCODEBUILD_BIN="$(command -v xcodebuild)"
else
  echo "error: xcodebuild not found. Install Xcode command line tools." >&2
  exit 1
fi

if [[ ${CLEAN} -eq 1 ]]; then
  rm -rf "${INSTALL_ROOT}"
fi

mkdir -p "${INSTALL_ROOT}"

echo "Building GhosttyKit.xcframework"
echo "  source: ${GHOSTTY_DIR}"
echo "  target: ${TARGET}"
echo "  optimize: ${OPTIMIZE}"
echo "  output: ${INSTALL_ROOT}"
echo "  staging: ${STAGING_ROOT}"

if [[ ${CLEAN} -eq 1 ]]; then
  rm -rf "${STAGING_ROOT}"
fi

(
  cd "${GHOSTTY_DIR}"
  export XCODEBUILD="${XCODEBUILD_BIN}"
  "${ZIG_BIN}" build \
    -Dapp-runtime=none \
    -Dsentry=false \
    -Demit-xcframework=true \
    -Dxcframework-target="${TARGET}" \
    -Doptimize="${OPTIMIZE}"
)

if [[ ! -d "${UPSTREAM_XCFRAMEWORK_PATH}" ]]; then
  echo "error: expected xcframework missing at ${UPSTREAM_XCFRAMEWORK_PATH}" >&2
  exit 1
fi

rm -rf "${XCFRAMEWORK_PATH}" "${RESOURCES_PATH}"
mkdir -p "${INSTALL_ROOT}/macos" "${INSTALL_ROOT}/share"
cp -R "${UPSTREAM_XCFRAMEWORK_PATH}" "${XCFRAMEWORK_PATH}"
if [[ -d "${STAGING_ROOT}/share/ghostty" ]]; then
  cp -R "${STAGING_ROOT}/share/ghostty" "${RESOURCES_PATH}"
fi

echo "Built xcframework:"
echo "  ${XCFRAMEWORK_PATH}"

if [[ -d "${RESOURCES_PATH}" ]]; then
  echo "Ghostty resources:"
  echo "  ${RESOURCES_PATH}"
fi
