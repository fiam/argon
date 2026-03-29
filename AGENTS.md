# AGENTS.md

## Project Purpose

Argon is a native macOS code review app for coding agents. It provides:

- A SwiftUI desktop app for GitHub-style diff review with inline comments.
- A CLI (`argon`) for agent-safe, non-interactive control.
- A skill-driven workflow where agents wait for reviewer input, address feedback, and re-request approval.

## Source of Truth

- Product requirements: `PRD.md`
- Skill contract: `skills/argon-app-review/SKILL.md`

If behavior conflicts, prioritize `PRD.md` and update the other docs.

## Collaboration Rules

1. Run `make check` before every commit; all checks must pass.
2. Add or update tests in the same commit as behavior changes.
3. Keep the CLI machine-readable first (`--json` output is required for agent workflows).
4. Keep all review states explicit (`awaiting_reviewer`, `awaiting_agent`, `approved`, `closed`).
5. Preserve comment thread identity across review iterations.
6. Avoid interactive prompts in agent-facing commands.
7. Favor deterministic behavior over convenience defaults.

## What `make check` runs

1. `cargo fmt` + `swift-format` — format all Rust and Swift code.
2. `cargo fmt --check` + `cargo clippy` + `swift-format lint` — verify formatting and lint.
3. `cargo deny check` — license and advisory audit.
4. `cargo test --workspace` — 39 Rust unit and integration tests.
5. `xcodebuild test` — 10 Swift unit tests (DiffParser, SessionLoader).

## Repository Structure

```
argon-native/
├── crates/
│   ├── argon-core/       # Domain types, ReviewBackend trait, LocalBackend
│   └── argon/            # CLI binary
├── apps/
│   └── macos/            # SwiftUI app (project.yml + sources, .xcodeproj gitignored)
│       ├── Sources/      # App source code
│       └── Tests/        # Swift unit tests
├── skills/               # Bundled agent skills
│   ├── argon-app-review/ # Production skill for coding agents
│   └── argon-dev-review/ # Dev skill for testing the app
├── scripts/              # Dev scripts
├── Makefile              # `make check`, `make fmt`, `make test`, etc.
├── deny.toml             # cargo-deny configuration
└── Cargo.toml            # Workspace root
```

## Development Workflow

- Use XcodeGen: `project.yml` is checked in, `.xcodeproj` is gitignored.
- Rebuild and launch for testing: `bash scripts/dev-argon.sh .`
- Install dev skill: `make install-dev-skill`
- Run all checks: `make check`
- Format code: `make fmt`

## Commit Conventions

- Short subject line (target 50 chars max).
- Body wrapped to 72 chars per line.
- One blank line between subject and body.
- Commit without GPG signature.

## Key Design Decisions

- **SwiftUI primary**: use SwiftUI for all UI, AppKit only for hard limitations (NSTextView, PTY terminals).
- **ReviewBackend trait**: the core abstraction. LocalBackend ships first; RemoteBackend enables SaaS mode later.
- **Per-session backends**: each app window holds one backend managing one session.
- **Skill-driven**: agents interact via CLI skills only. The app is the human's surface.
- **Draft review mode**: comments accumulate as drafts, submitted together with a decision (like GitHub).
- **FSEvents file watcher**: diff refreshes automatically when the working tree changes.
