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

Environment:
  ZIG=/abs/path/to/zig         Override Zig auto-discovery. The binary must
                               match Ghostty's pinned minimum Zig version.
                               Recommended default install:
                               brew install zig@0.15
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GHOSTTY_DIR="${REPO_ROOT}/third_party/ghostty"
HOST_ARCH="$(uname -m)"

TARGET="native"
OPTIMIZE="Debug"
OUTPUT_ROOT="${REPO_ROOT}/target/libghostty"
CLEAN=0
PRINT_PATH=0
PRINT_RESOURCES_PATH=0
STAGING_ROOT="${GHOSTTY_DIR}/zig-out"
UPSTREAM_XCFRAMEWORK_PATH="${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"
REQUIRED_ZIG_VERSION=""
ZIG_BIN=""
ZIG_ARCH=""

declare -a ZIG_CANDIDATES=()

fail() {
  echo "error: $*" >&2
  exit 1
}

note() {
  echo "note: $*" >&2
}

add_zig_candidate() {
  local candidate="$1"
  local existing=""

  [[ -n "${candidate}" ]] || return 0
  [[ -x "${candidate}" ]] || return 0

  for existing in "${ZIG_CANDIDATES[@]}"; do
    if [[ "${existing}" == "${candidate}" ]]; then
      return 0
    fi
  done

  ZIG_CANDIDATES+=("${candidate}")
}

detect_binary_arch() {
  local binary="$1"
  local file_output=""

  file_output="$(file -b "${binary}" 2>/dev/null || true)"
  case "${file_output}" in
    *arm64*) printf 'arm64\n' ;;
    *x86_64*) printf 'x86_64\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

zig_version() {
  local zig_bin="$1"
  "${zig_bin}" version 2>/dev/null || true
}

load_required_zig_version() {
  REQUIRED_ZIG_VERSION="$(
    sed -n -E \
      's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
      "${GHOSTTY_DIR}/build.zig.zon" | head -1
  )"

  [[ -n "${REQUIRED_ZIG_VERSION}" ]] || fail "could not determine Ghostty's required Zig version from ${GHOSTTY_DIR}/build.zig.zon"
}

print_zig_search_hints() {
  local candidate=""
  local candidate_arch=""
  local candidate_version=""

  if [[ ${#ZIG_CANDIDATES[@]} -gt 0 ]]; then
    echo "searched Zig candidates:" >&2
    for candidate in "${ZIG_CANDIDATES[@]}"; do
      candidate_arch="$(detect_binary_arch "${candidate}")"
      candidate_version="$(zig_version "${candidate}" || printf 'unknown')"
      echo "  ${candidate} (${candidate_arch}, ${candidate_version})" >&2
    done
  fi

  echo "hint: install Homebrew zig@0.15 or set ZIG=/abs/path/to/zig" >&2
}

select_zig() {
  local path_zig=""
  local candidate=""
  local candidate_version=""
  local candidate_arch=""
  local -a native_matches=()

  if [[ -n "${ZIG:-}" ]]; then
    [[ -x "${ZIG}" ]] || fail "ZIG is set to a non-executable path: ${ZIG}"
    candidate_version="$(zig_version "${ZIG}")"
    [[ "${candidate_version}" == "${REQUIRED_ZIG_VERSION}" ]] || fail "ZIG points to Zig ${candidate_version}, but Ghostty requires Zig ${REQUIRED_ZIG_VERSION}"
    ZIG_BIN="${ZIG}"
    ZIG_ARCH="$(detect_binary_arch "${ZIG_BIN}")"
    if [[ "${ZIG_ARCH}" != "unknown" && "${ZIG_ARCH}" != "${HOST_ARCH}" ]]; then
      fail "ZIG points to a ${ZIG_ARCH} binary on a ${HOST_ARCH} host. Use a host-native Zig ${REQUIRED_ZIG_VERSION} toolchain."
    fi
    return
  fi

  path_zig="$(command -v zig 2>/dev/null || true)"
  add_zig_candidate "${path_zig}"
  add_zig_candidate "/opt/homebrew/bin/zig"
  add_zig_candidate "/opt/homebrew/opt/zig@0.15/bin/zig"
  add_zig_candidate "/usr/local/bin/zig"
  add_zig_candidate "${HOME}/.local/bin/zig"
  add_zig_candidate "${HOME}/bin/zig"
  add_zig_candidate "${HOME}/.local/opt/zig-aarch64-macos-${REQUIRED_ZIG_VERSION}/zig"
  add_zig_candidate "${HOME}/.local/opt/zig-arm64-macos-${REQUIRED_ZIG_VERSION}/zig"
  add_zig_candidate "${HOME}/.local/opt/zig-x86_64-macos-${REQUIRED_ZIG_VERSION}/zig"

  for candidate in "${ZIG_CANDIDATES[@]}"; do
    candidate_version="$(zig_version "${candidate}")"
    if [[ "${candidate_version}" != "${REQUIRED_ZIG_VERSION}" ]]; then
      continue
    fi

    candidate_arch="$(detect_binary_arch "${candidate}")"
    if [[ "${candidate_arch}" == "${HOST_ARCH}" || "${candidate_arch}" == "unknown" ]]; then
      native_matches+=("${candidate}")
    fi
  done

  if [[ ${#native_matches[@]} -gt 0 ]]; then
    ZIG_BIN="${native_matches[0]}"
    ZIG_ARCH="$(detect_binary_arch "${ZIG_BIN}")"
    return
  fi

  echo "error: could not find a host-native Zig ${REQUIRED_ZIG_VERSION} toolchain for Ghostty" >&2
  print_zig_search_hints
  exit 1
}

run_zig() {
  local zig_bin="$1"
  shift

  "${zig_bin}" "$@"
}

build_with_zig() {
  local zig_bin="$1"
  local zig_arch=""
  local zig_version_value=""

  zig_arch="$(detect_binary_arch "${zig_bin}")"
  zig_version_value="$(zig_version "${zig_bin}")"

  echo "  zig: ${zig_bin} (${zig_arch}, ${zig_version_value})"

  (
    cd "${GHOSTTY_DIR}"
    export XCODEBUILD="${XCODEBUILD_BIN}"
    run_zig "${zig_bin}" build \
      -Dapp-runtime=none \
      -Dsentry=false \
      -Demit-xcframework=true \
      -Dxcframework-target="${TARGET}" \
      -Doptimize="${OPTIMIZE}"
  )
}

require_metal_tools() {
  local missing=()

  if ! "${XCRUN_BIN}" -sdk macosx --find metal >/dev/null 2>&1; then
    missing+=("metal")
  fi

  if ! "${XCRUN_BIN}" -sdk macosx --find metallib >/dev/null 2>&1; then
    missing+=("metallib")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing Xcode Metal tools (${missing[*]})" >&2
    echo "hint: run 'xcodebuild -downloadComponent MetalToolchain'" >&2
    exit 1
  fi
}

reset_upstream_outputs() {
  rm -rf "${UPSTREAM_XCFRAMEWORK_PATH}" "${STAGING_ROOT}/share/ghostty"
}

have_upstream_artifacts() {
  [[ -d "${UPSTREAM_XCFRAMEWORK_PATH}" && -d "${STAGING_ROOT}/share/ghostty" ]]
}

attempt_build() {
  local zig_bin="$1"

  reset_upstream_outputs
  if build_with_zig "${zig_bin}"; then
    return 0
  fi

  if have_upstream_artifacts; then
    note "Ghostty returned a non-zero status after producing the xcframework and resources; continuing with the generated artifacts"
    return 0
  fi

  return 1
}

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

if [[ -n "${XCODEBUILD:-}" && -x "${XCODEBUILD}" ]]; then
  XCODEBUILD_BIN="${XCODEBUILD}"
elif command -v xcodebuild >/dev/null 2>&1; then
  XCODEBUILD_BIN="$(command -v xcodebuild)"
else
  echo "error: xcodebuild not found. Install Xcode command line tools." >&2
  exit 1
fi

if [[ -n "${XCRUN:-}" && -x "${XCRUN}" ]]; then
  XCRUN_BIN="${XCRUN}"
elif command -v xcrun >/dev/null 2>&1; then
  XCRUN_BIN="$(command -v xcrun)"
else
  echo "error: xcrun not found. Install Xcode command line tools." >&2
  exit 1
fi

load_required_zig_version
select_zig
require_metal_tools

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
echo "  required zig: ${REQUIRED_ZIG_VERSION}"

if [[ ${CLEAN} -eq 1 ]]; then
  rm -rf "${STAGING_ROOT}" "${UPSTREAM_XCFRAMEWORK_PATH}"
fi

attempt_build "${ZIG_BIN}"

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
