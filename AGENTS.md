# AGENTS.md

## Project Purpose

Argon is a native macOS workspace for coding agents. It provides:

- A SwiftUI desktop app for managing Git worktrees, terminals, and review.
- A CLI (`argon`) for agent-safe, non-interactive control.
- A review workflow that can be launched from the UI or from the CLI,
  while agents may follow either prompt-driven or skill-backed handoff.

## Source of Truth

- Product requirements: `PRD.md`
- Skill contract: `skills/argon-app-review/SKILL.md`

If behavior conflicts, prioritize `PRD.md` and update the other docs.

## Collaboration Rules

1. Run `make check` before every commit; all checks must pass.
2. Add or update unit tests and UI tests in the same commit as behavior
   changes; new workspace and review flows should have extensive coverage.
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

- Initialize the Ghostty submodule once:
  `git submodule update --init --recursive third_party/ghostty`
- Install the recommended Zig toolchain for vendored Ghostty:
  `brew install zig@0.15`
- Install the Xcode Metal Toolchain component for Ghostty:
  `xcodebuild -downloadComponent MetalToolchain`
- Ghostty currently pins Zig `0.15.2`. In practice the supported local
  setup is Homebrew `zig@0.15`, which installs a patched `0.15.2` build at
  `/opt/homebrew/opt/zig@0.15/bin/zig`. `scripts/build-libghostty.sh`
  prefers that path automatically, or you can set `ZIG=/abs/path/to/zig`.
- Build or refresh vendored Ghostty with:
  `bash scripts/build-libghostty.sh`
- Use XcodeGen: `project.yml` is checked in, `.xcodeproj` is gitignored.
- Rebuild and launch for testing: `bash scripts/dev-argon.sh .`
- `scripts/dev-argon.sh` builds the Rust CLI, regenerates the Xcode
  project, builds `Argon.app`, and launches the requested workspace.
- Install dev skill: `make install-dev-skill`
- Run all checks: `make check`
- Format code: `make fmt`

## Commit Conventions

- Use Conventional Commits:
  `<type>(<scope>): <summary>` (scope optional).
- Supported types: `feat`, `fix`, `refactor`, `docs`, `test`, `build`,
  `ci`, `chore`, `perf`, `revert`.
- Subject line must be imperative and target 50 chars max.
- Include a commit body for every commit.
- Wrap body lines at 72 chars.
- Keep exactly one blank line between subject and body.
- Commit without GPG signature.

## Key Design Decisions

- **SwiftUI primary**: use SwiftUI for all UI, AppKit only for hard limitations (NSTextView, PTY terminals).
- **ReviewBackend trait**: the core abstraction. LocalBackend ships first; RemoteBackend enables SaaS mode later.
- **Per-session backends**: each app window holds one backend managing one session.
- **Dual review entry**: review can start from the workspace UI or from the
  CLI.
- **Prompt-first agent handoff**: agents may be driven entirely through
  copied prompts and CLI commands; bundled skills are optional wrappers.
- **Draft review mode**: comments accumulate as drafts, submitted together with a decision (like GitHub).
- **FSEvents file watcher**: diff refreshes automatically when the working tree changes.
