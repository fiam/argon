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
- Keep the CLI machine-readable first. `--json` output is required for
  agent workflows.
- Keep review states explicit:
  `awaiting_reviewer`, `awaiting_agent`, `approved`, `closed`.
- Preserve comment thread identity across review iterations.
- Avoid interactive prompts in agent-facing commands.
- Favor deterministic behavior over convenience defaults.

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
