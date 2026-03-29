#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_SRC="$REPO_ROOT/skills/argon-dev-review"

install_to() {
    local name="$1"
    local home="$2"
    local dest="$home/argon-dev-review"

    mkdir -p "$home"
    rm -rf "$dest"
    cp -R "$SKILL_SRC" "$dest"

    # Stamp the checkout path so the skill knows where to find argon
    printf '%s\n' "$REPO_ROOT" > "$dest/.argon-src"

    echo "installed argon-dev-review for $name at $dest (source: $REPO_ROOT)"
}

# Claude Code
CLAUDE_SKILLS="$HOME/.claude/skills"
install_to "Claude Code" "$CLAUDE_SKILLS"

# Codex
CODEX_SKILLS="$HOME/.codex/skills"
install_to "Codex" "$CODEX_SKILLS"

echo ""
echo "Done. Use from any project:"
echo "  /argon-dev-review (in Claude Code or Codex)"
