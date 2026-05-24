# AGENTS.md

## Project Purpose

Argon is a native macOS workspace for coding agents. It provides:

- A SwiftUI desktop app for managing Git worktrees, terminals, and review.
- A CLI (`argon`) for agent-safe, non-interactive control.
- A review workflow that can be launched from the UI or from the CLI,
  while agents follow prompt-driven or direct CLI handoff.

## Source of Truth

- Product requirements: `PRD.md`
- CLI protocol contract: `crates/argon-core/src/protocol.rs`
- Prompt contract: `crates/argon-core/src/prompt.rs`

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
8. Keep refactors behavior-preserving unless the user explicitly asks for
   product changes.
9. Prefer small, focused source files over monolithic files; split by
   workflow, UI surface, or domain responsibility when a file becomes hard
   for agents to inspect safely.

## Refactoring Guidelines

- Refactor for readability, navigation, testability, or clearer ownership;
  do not use a refactor pass to add features, redesign UI, or change
  workflow semantics.
- Keep behavior-preserving moves mechanical when possible: preserve public
  names, accessibility identifiers, persisted data shapes, CLI output, and
  review state transitions.
- Split SwiftUI views by surface and responsibility. Window/root views should
  orchestrate state, navigation, sheets, and environment wiring; sidebar,
  inspector, terminal, review, and shared controls should live in focused
  files.
- Keep model and service logic out of SwiftUI view files unless it is truly
  presentation-only. Move reusable logic into `Models/` or `Services/`.
- When extracting code across Swift files, remember that cross-file helper
  types cannot be `private`; keep names explicit and scoped by prefix
  instead of making generic top-level names.
- For pure refactors, update or add tests only when behavior is clarified or
  risk changes; still run `make check` before commit.

## What `make check` runs

1. `cargo fmt` + `swift-format` — format all Rust and Swift code.
2. `cargo fmt --check` + `cargo clippy` + `swift-format lint` — verify formatting and lint.
3. `scripts/check-release-metadata.sh` — verify release metadata is synchronized.
4. `cargo deny check` — license and advisory audit.
5. `cargo test --workspace` — Rust unit and integration tests.
6. Swift app build — regenerate the Xcode project and build `Argon.app`.
7. `xcodebuild test` — Swift unit tests.

## Repository Structure

```
argon/
├── crates/
│   ├── argon/            # CLI binary
│   ├── argon-core/       # Domain types, diff/review logic, and protocol types
│   ├── argon-lib/        # FFI bridge used by the macOS app
│   └── sandbox/          # Sandboxfile parser, evaluator, and macOS backend
├── apps/
│   └── macos/            # SwiftUI app (project.yml + sources, .xcodeproj gitignored)
│       ├── Sources/      # App source code
│       └── Tests/        # Swift unit tests
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
- **Local session store first**: review sessions are local files managed by
  `argon-core`; remote review backends remain a future direction in the PRD.
- **Dual review entry**: review can start from the workspace UI or from the
  CLI.
- **App/CLI-first agent handoff**: agents are driven through app-generated
  prompts and direct CLI commands.
- **Draft review mode**: comments accumulate as drafts, submitted together with a decision (like GitHub).
- **FSEvents file watcher**: diff refreshes automatically when the working tree changes.
