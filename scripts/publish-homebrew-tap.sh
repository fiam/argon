#!/usr/bin/env bash

set -euo pipefail

TAP_REPOSITORY="${ARGON_HOMEBREW_TAP_REPOSITORY:-fiam/homebrew-tap}"
APP_REPOSITORY="${ARGON_REPOSITORY:-fiam/argon}"
SSH_KEY_PATH="${ARGON_HOMEBREW_TAP_SSH_KEY:-}"
GIT_AUTHOR_NAME="${ARGON_HOMEBREW_TAP_GIT_NAME:-github-actions[bot]}"
GIT_AUTHOR_EMAIL="${ARGON_HOMEBREW_TAP_GIT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
CASK_PATH=""

function usage() {
  cat <<EOF >&2
usage: $0 --cask <path> [--tap-repo <owner/repo>] [--ssh-key <path>] [--app-repo <owner/repo>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cask)
      CASK_PATH="${2:-}"
      shift 2
      ;;
    --tap-repo)
      TAP_REPOSITORY="${2:-}"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY_PATH="${2:-}"
      shift 2
      ;;
    --app-repo)
      APP_REPOSITORY="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$CASK_PATH" || ! -f "$CASK_PATH" ]]; then
  usage
  exit 1
fi

WORK_DIR="$(mktemp -d)"
SSH_DIR="$WORK_DIR/ssh"
TAP_DIR="$WORK_DIR/tap"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ -n "$SSH_KEY_PATH" ]]; then
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  cp "$SSH_KEY_PATH" "$SSH_DIR/key"
  chmod 600 "$SSH_DIR/key"
  ssh-keyscan github.com > "$SSH_DIR/known_hosts"
  export GIT_SSH_COMMAND="ssh -i $SSH_DIR/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=yes"
fi

git clone "git@github.com:${TAP_REPOSITORY}.git" "$TAP_DIR"

mkdir -p "$TAP_DIR/Casks"
cp "$CASK_PATH" "$TAP_DIR/Casks/argon.rb"

git -C "$TAP_DIR" config user.name "$GIT_AUTHOR_NAME"
git -C "$TAP_DIR" config user.email "$GIT_AUTHOR_EMAIL"
git -C "$TAP_DIR" add Casks/argon.rb

if git -C "$TAP_DIR" diff --cached --quiet; then
  echo "homebrew tap already up to date"
  exit 0
fi

VERSION="$(sed -nE 's/^  version "(.*)"$/\1/p' "$CASK_PATH" | head -n 1)"
if [[ -n "$VERSION" ]]; then
  COMMIT_SUBJECT="Update argon cask to ${VERSION}"
else
  COMMIT_SUBJECT="Update argon cask"
fi

git -C "$TAP_DIR" commit -m "$COMMIT_SUBJECT"
git -C "$TAP_DIR" push origin main
