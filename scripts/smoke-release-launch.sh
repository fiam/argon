#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARGON_BIN="$REPO_ROOT/target/release/argon"
SKIP_BUILD=0

usage() {
    cat >&2 <<EOF
usage: $0 [--skip-build]

Build and smoke-test the release CLI launcher behavior without opening the
real Argon app.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_empty_file() {
    local path="$1"
    local label="$2"
    if [[ -s "$path" ]]; then
        echo "unexpected $label:" >&2
        sed 's/^/  /' "$path" >&2
        exit 1
    fi
}

assert_contains() {
    local path="$1"
    local pattern="$2"
    if ! grep -F -- "$pattern" "$path" >/dev/null 2>&1; then
        echo "expected $path to contain: $pattern" >&2
        echo "actual contents:" >&2
        sed 's/^/  /' "$path" >&2
        exit 1
    fi
}

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "==> Building release argon CLI"
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin argon --release
fi

[[ -x "$ARGON_BIN" ]] || fail "release argon binary not found at $ARGON_BIN"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/argon-release-launch.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

REPO_DIR="$WORK_DIR/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "argon-smoke@example.com"
git -C "$REPO_DIR" config user.name "Argon Smoke"
printf '# Smoke\n' > "$REPO_DIR/README.md"
git -C "$REPO_DIR" add README.md
git -C "$REPO_DIR" commit -q -m "initial"

echo "==> Checking release workspace launch stays quiet with an explicit launcher"
stdout_file="$WORK_DIR/workspace-explicit.stdout"
stderr_file="$WORK_DIR/workspace-explicit.stderr"
(
    cd "$REPO_DIR"
    ARGON_DESKTOP_LAUNCH=/usr/bin/true "$ARGON_BIN" . >"$stdout_file" 2>"$stderr_file"
)
assert_empty_file "$stdout_file" "workspace stdout"
assert_empty_file "$stderr_file" "workspace stderr"

if [[ "$(uname -s)" == "Darwin" ]]; then
    FAKE_BIN="$WORK_DIR/bin"
    OPEN_LOG="$WORK_DIR/open.log"
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${ARGON_OPEN_LOG:?}"

if [[ "${1:-}" == "-b" && "${2:-}" == "dev.argonapp.macos" ]]; then
    exit 0
fi

exit 1
EOF
    chmod +x "$FAKE_BIN/open"

    echo "==> Checking release workspace launch uses Launch Services URL fallback"
    stdout_file="$WORK_DIR/workspace-launch-services.stdout"
    stderr_file="$WORK_DIR/workspace-launch-services.stderr"
    : > "$OPEN_LOG"
    (
        cd "$REPO_DIR"
        unset ARGON_APP ARGON_DESKTOP_LAUNCH
        PATH="$FAKE_BIN:$PATH" ARGON_OPEN_LOG="$OPEN_LOG" "$ARGON_BIN" . \
            >"$stdout_file" 2>"$stderr_file"
    )
    assert_empty_file "$stdout_file" "workspace Launch Services stdout"
    assert_empty_file "$stderr_file" "workspace Launch Services stderr"
    assert_contains "$OPEN_LOG" "-b dev.argonapp.macos argon://workspace?"

    echo "==> Checking release review launch uses Launch Services URL fallback"
    stdout_file="$WORK_DIR/review-launch-services.stdout"
    stderr_file="$WORK_DIR/review-launch-services.stderr"
    : > "$OPEN_LOG"
    (
        cd "$REPO_DIR"
        unset ARGON_APP ARGON_DESKTOP_LAUNCH
        PATH="$FAKE_BIN:$PATH" ARGON_OPEN_LOG="$OPEN_LOG" \
            "$ARGON_BIN" review --mode uncommitted . >"$stdout_file" 2>"$stderr_file"
    )
    assert_empty_file "$stderr_file" "review Launch Services stderr"
    assert_contains "$stdout_file" "session:"
    assert_contains "$OPEN_LOG" "-b dev.argonapp.macos argon://review?"
fi

echo "==> Checking local development launcher script syntax"
bash -n "$REPO_ROOT/scripts/dev-argon.sh"

echo "release launch smoke passed"
