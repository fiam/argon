# Development

This document is for building, testing, and contributing to Argon.

For the product overview, start with the [README](../README.md).

## Prerequisites

- Rust toolchain with Cargo
- Xcode
- Homebrew `zig@0.15`
- Xcode Metal Toolchain component for Ghostty
- XcodeGen
- `swift-format`

Install the recommended local toolchain with:

```bash
brew install zig@0.15 xcodegen swift-format
xcodebuild -downloadComponent MetalToolchain
git submodule update --init --recursive third_party/ghostty
```

Ghostty currently pins Zig `0.15.2`. In practice the supported local
setup is the Homebrew `zig@0.15` formula, which installs a patched
`0.15.2` build at `/opt/homebrew/opt/zig@0.15/bin/zig`.

Before the first macOS app build:

```bash
bash scripts/build-libghostty.sh
```

`scripts/build-libghostty.sh` auto-discovers the vendored Ghostty Zig
requirement from `third_party/ghostty/build.zig.zon` and prefers the
Homebrew `zig@0.15` install when it is available. You can still override
that with `ZIG=/abs/path/to/zig`.

## Common Commands

```bash
make build-libghostty
make fmt
make test
make check
bash scripts/dev-argon.sh .
```

Typical macOS build flow:

- `make build-libghostty` or `bash scripts/build-libghostty.sh`
  builds `target/libghostty/native/macos/GhosttyKit.xcframework` and
  `target/libghostty/native/share/ghostty`
- `bash scripts/dev-argon.sh .`
  builds the Rust CLI, regenerates `apps/macos/Argon.xcodeproj`, builds
  `Argon.app`, and launches the current repo workspace
- `make build-release`
  builds the release app and refreshes vendored Ghostty as part of that
  flow

## Checks

`make check` currently runs:

1. `cargo fmt` + `swift-format`
2. `cargo fmt --check` + `cargo clippy` + `swift-format lint`
3. `cargo deny check`
4. `cargo test --workspace`
5. `xcodebuild test`

Run `make check` before every commit.

## Contribution Rules

- Add or update unit tests and UI tests in the same commit as behavior
  changes.
- Keep pure refactors behavior-preserving. Do not add product behavior,
  redesign UI, or change workflow semantics in the same change.
- Keep large files from becoming difficult for agents to inspect safely.
  Split code by workflow, surface, or domain responsibility when ownership
  becomes unclear.
- Keep the CLI machine-readable first. `--json` output is required for
  agent workflows.
- Keep review states explicit:
  `awaiting_reviewer`, `awaiting_agent`, `approved`, `closed`.
- Preserve comment thread identity across review iterations.
- Avoid interactive prompts in agent-facing commands.
- Favor deterministic behavior over convenience defaults.

## Refactoring Guidelines

Refactors should make future changes easier without changing what users or
agents observe. Preserve public names, accessibility identifiers, serialized
data shapes, CLI output, and review state transitions unless the requested
work explicitly changes them.

For SwiftUI code:

- Keep scene and window root views focused on orchestration: state wiring,
  navigation, sheets, alerts, toolbars, and environment setup.
- Put sidebar, terminal, inspector, review, agent launch, and shared controls
  in focused files instead of one large view file.
- Move reusable model or service behavior into `Models/` or `Services/`.
  View files should only contain presentation logic and local UI helpers.
- When helpers are needed across Swift files, use explicit Argon-specific
  names and prefixes. Swift `private` declarations do not cross file
  boundaries.

For Rust code:

- Keep CLI command parsing, command execution, prompt construction, sandbox
  operations, and output formatting in separate modules when they grow.
- Keep machine-readable response structs close to the commands that emit
  them, and avoid ad hoc text parsing when structured data is available.

Run `make check` after refactors. For very small intermediate moves, at least
run the relevant formatter and targeted build/test before continuing.

## Commit Conventions

Use Conventional Commits:

```text
<type>(<scope>): <summary>
```

- supported types:
  `feat`, `fix`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`,
  `perf`, `revert`
- subject line: imperative, target 50 chars max
- include a commit body for every commit
- wrap body lines at 72 chars
- keep exactly one blank line between subject and body
- commit without GPG signature

## Project Generation

The macOS project is generated from `apps/macos/project.yml`. Regenerate
it with XcodeGen instead of editing `.xcodeproj` by hand.

## Related Docs

- [Architecture and repo layout](architecture.md)
- [Ghostty integration notes](ghostty-integration.md)
- [Sandbox reference](../SANDBOX.md)
- [Product requirements](../PRD.md)
