# Argon

Argon is a native macOS workspace for coding agents.

It combines:

- a SwiftUI desktop app for managing worktrees, terminals, and review
- a bundled `argon` CLI for convenient app launch and machine-readable
  agent workflows
- a local-first review loop that still works both from the app and from a shell

Product detail lives in [PRD.md](PRD.md). The agent-facing review contract
lives in [skills/argon-app-review/SKILL.md](skills/argon-app-review/SKILL.md).
That skill is an optional wrapper, not the only supported agent path.

## What Argon Does

Argon gives the human a single place to coordinate agent work:

- open or focus the right Argon window from the terminal with `argon <dir>`
- manage multiple worktrees in one repository window
- work in embedded agent terminals or bare shell tabs
- inspect diffs and launch formal review when ready
- launch reviewer agents such as Claude, Codex, Gemini, or a custom command
- keep review sessions explicit and machine-readable through the CLI

The same review flow also works without the app initiating it. An agent can
start a session from a shell, block for reviewer feedback, address comments,
and wait for approval through `argon agent ...` commands.

Humans can also start review directly from the app by clicking the
workspace `Review` button, or from the terminal with `argon review <dir>`.
Agents can be driven entirely by copied prompts and CLI commands; installed
skills are optional convenience.

Planned v2 direction:

- an in-app MCP server so embedded agents can call Argon tools directly
- typed workspace actions for creating worktrees
- typed review actions for asking another saved agent profile to review
- centrally managed connector support so agents can be connected to shared
  services from one place through MCP and optional skill wrappers

## Command Line Tool

Argon bundles an `argon` CLI inside the app and expects a symlink at
`/usr/local/bin/argon`.

On launch, the macOS app checks that link. If it is missing or broken, Argon
shows a startup dialog offering to install or fix it. That link enables:

- `argon <dir>` to open Argon focused on a repository or worktree
- `argon review <dir>` to open the review UI for a repository from the shell

You can always inspect the current status or repair the link later in
Settings > General.

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
  Bundled optional skills that wrap the review loop for compatible agents.

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

Argon can launch reviewer agents inside a local sandbox on macOS.

That sandbox is driven by `Sandboxfile` discovery up the parent-directory
chain, including `.Sandboxfile` and legacy `.Sanboxfile` variants. It
currently covers filesystem writes, executable policy, environment shaping,
command interception, and network policy through direct socket rules or a
local HTTP(S) proxy. Repo
policies can also include optional relative modules such as
`./Sandboxfile.local`, and users can create `$HOME/.Sandboxfile` for
policy that should apply after repo-local sandbox files. Use
`argon sandbox check` to validate the resolved
policy stack for the current launch context. In the macOS app, requesting a
sandboxed shell or agent with no resolved `Sandboxfile` shows a confirmation
dialog that explains the default scaffold, including the built-in `git`
module, and creates it before launch.

On macOS today, direct `NET ALLOW CONNECT` rules are intentionally narrow:
localhost or `*:port` shapes only. Hostname-based policy belongs under
`NET ALLOW PROXY ...`. See [SANDBOX.md](SANDBOX.md) for the exact currently
supported syntax. When a sandboxed workspace tab uses proxy-backed network
rules, the app inspector shows the observed proxied requests for that tab.
With `NET DEFAULT ALLOW`, proxy rules stay passive instead of forcing
traffic through the proxy.

Sandbox documentation:

- [SANDBOX.md](SANDBOX.md)

## Development

Requirements:

- Rust toolchain with Cargo
- Xcode
- Homebrew `zig@0.15` for vendored Ghostty:
  `brew install zig@0.15`
- Xcode Metal Toolchain component for Ghostty:
  `xcodebuild -downloadComponent MetalToolchain`
- XcodeGen
- `swift-format`
- vendored Ghostty still pins Zig `0.15.2`. The supported local setup is
  the Homebrew `zig@0.15` formula, which installs a patched `0.15.2` build
  at `/opt/homebrew/opt/zig@0.15/bin/zig`

Recommended first-time macOS setup:

```bash
brew install zig@0.15 xcodegen swift-format
xcodebuild -downloadComponent MetalToolchain
git submodule update --init --recursive third_party/ghostty
```

Before the first macOS app build:

```bash
bash scripts/build-libghostty.sh
```

`scripts/build-libghostty.sh` auto-discovers the vendored Ghostty Zig
requirement from `third_party/ghostty/build.zig.zon` and prefers the
Homebrew `zig@0.15` install when it is available. You can still override
that with `ZIG=/abs/path/to/zig`.

Common commands:

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
  builds the release app and refreshes vendored Ghostty as part of that flow

Project rules worth keeping in mind:

- `make check` must pass before commits
- unit tests and UI tests should ship with behavior changes
- the CLI stays machine-readable first
- review states stay explicit

The macOS project is generated from `apps/macos/project.yml`. Regenerate it
with XcodeGen instead of editing `.xcodeproj` by hand.

The planned Ghostty terminal migration is documented in
[docs/ghostty-integration.md](docs/ghostty-integration.md). The dev and
release build scripts call `scripts/build-libghostty.sh` automatically, and
`make build-libghostty` is the direct way to refresh the vendored
`GhosttyKit.xcframework`.
