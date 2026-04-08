# Argon

Argon is a native macOS code review app for coding agents.

It combines:

- a SwiftUI desktop app for human review
- a bundled `argon` CLI for machine-readable agent workflows
- a local-first review loop that works both from the app and from a shell

Product detail lives in [PRD.md](PRD.md). The agent-facing review contract
lives in [skills/argon-app-review/SKILL.md](skills/argon-app-review/SKILL.md).

## What Argon Does

Argon gives the human a single place to coordinate agent work:

- open a repo in the macOS app
- inspect diffs with inline comments and draft review submission
- launch reviewer agents such as Claude, Codex, Gemini, or a custom command
- keep review sessions explicit and machine-readable through the CLI

The same review flow also works without the app initiating it. An agent can
start a session from a shell, block for reviewer feedback, address comments,
and wait for approval through `argon agent ...` commands.

## Main Pieces

- `apps/macos`
  The native macOS app.
- `crates/argon-core`
  Review sessions, diffs, storage, and shared domain logic.
- `crates/argon`
  The CLI binary.
- `crates/sandbox`
  Cross-platform sandbox abstraction with a macOS implementation today.
- `skills/`
  Bundled skills that agents use to enter and stay inside the review loop.

## Review Loop

Typical CLI-driven review flow:

```bash
argon agent start --repo . --mode uncommitted \
  --description "Review current changes" --wait --json
```

After the reviewer responds:

```bash
argon agent ack --session <session> --thread <thread> --json
argon agent reply --session <session> --thread <thread> \
  --message "Fixed in parser fallback" --addressed --json
argon agent wait --session <session> --json
```

Reviewer agents launched from the app are advisory reviewers. They can comment
or request changes, but only the human reviewer can approve the session.

## Sandbox

Argon can launch reviewer agents inside a filesystem sandbox. That mode is
currently optional and disabled by default.

When enabled, Argon keeps the reviewed repo writable, keeps Argon session
storage writable, and applies additional writable paths from built-in defaults
plus user and repo sandbox config files.

Sandbox documentation:

- [SANDBOX.md](SANDBOX.md)

## Development

Requirements:

- Rust toolchain with Cargo
- Xcode
- XcodeGen
- `swift-format`

Common commands:

```bash
make fmt
make test
make check
bash scripts/dev-argon.sh .
```

Project rules worth keeping in mind:

- `make check` must pass before commits
- tests should ship with behavior changes
- the CLI stays machine-readable first
- review states stay explicit

The macOS project is generated from `apps/macos/project.yml`. Regenerate it
with XcodeGen instead of editing `.xcodeproj` by hand.
