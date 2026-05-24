# libghostty Integration

Argon embeds vendored Ghostty for in-app terminal tabs while keeping launch
policy, sandboxing, and tab/session lifecycle in Argon.

This note records the current upstream boundary and the runtime/build
constraints for the embedded terminal.

## Upstream Pin

Ghostty is vendored as a git submodule at `third_party/ghostty`.

- upstream repo: `https://github.com/ghostty-org/ghostty`
- current tag: `v1.3.1`
- pinned commit: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`

Update procedure:

```bash
git submodule update --init --recursive third_party/ghostty
cd third_party/ghostty
git fetch --tags origin
git checkout <tag-or-commit>
cd ../..
git add .gitmodules third_party/ghostty
```

## Current Upstream Embedding Boundary

These vendored upstream files are the source of truth for the current
integration approach:

- `third_party/ghostty/include/ghostty.h`
  C API surface that Swift can bridge against.
- `third_party/ghostty/src/main_c.zig`
  Notes that the C API is the embedding layer and is not yet a stable
  general-purpose API.
- `third_party/ghostty/src/apprt/embedded.zig`
  Defines the embedded runtime, the macOS `NSView` hook, and surface
  options such as `working_directory` and `command`.
- `third_party/ghostty/build.zig`
  Confirms that Darwin `libghostty` builds currently ship as an
  `xcframework`, not a reusable `.dylib`/`.a` install.

Important constraints from upstream:

- `libghostty` is used by Ghostty's own macOS app but is not yet treated
  upstream as a stable embeddable SDK.
- On Darwin, the supported packaging artifact is
  `GhosttyKit.xcframework`.

## Argon Ownership Boundary

Argon should keep ownership of:

- terminal command construction
- sandbox and environment policy
- repo/session working-directory rules
- terminal tab state and lifecycle
- app-specific notifications and review metadata

Ghostty should only replace the in-app terminal renderer and the PTY-facing
terminal surface.

That means the current terminal launch configuration and supporting launch
helpers stay the entry point. The Ghostty wrapper accepts the same launch
inputs that Argon owns:

- executable/args represented as a shell command
- environment variables
- current directory
- process exit callbacks

## Build Artifact

Argon builds Ghostty through the vendored source tree, not through SwiftPM.

The helper script is:

```bash
bash scripts/build-libghostty.sh
```

Build requirements:

- initialize the submodule with
  `git submodule update --init --recursive third_party/ghostty`
- install the recommended Zig toolchain with
  `brew install zig@0.15`
- upstream Ghostty currently pins Zig `0.15.2`. The helper script reads the
  required version from `third_party/ghostty/build.zig.zon`, prefers the
  Homebrew `zig@0.15` install at `/opt/homebrew/opt/zig@0.15/bin/zig`,
  auto-discovers matching installs from common local paths, and also accepts
  `ZIG=/abs/path/to/zig`
- install Xcode's Metal Toolchain component because Ghostty's renderer build
  shells out to `metal` and `metallib`:
  `xcodebuild -downloadComponent MetalToolchain`
- use a host-native Zig toolchain. On Apple Silicon that means an `arm64`
  Zig `0.15.2` install, not an `x86_64` Zig binary under Rosetta

Default behavior:

- builds a native macOS debug `GhosttyKit.xcframework`
- validates that the required Zig version is available before starting the
  build
- fails early with the Metal Toolchain install command when `metal` or
  `metallib` are unavailable
- uses Ghostty's own `third_party/ghostty/zig-out` staging layout because
  the upstream macOS project expects resources there during the build
- installs into `target/libghostty/native`
- keeps the artifact path deterministic for Xcode integration
- the Argon app build copies `share/ghostty` into the app bundle so the
  embedded runtime can resolve Ghostty resources without depending on the
  repo checkout at runtime

Useful variants:

```bash
bash scripts/build-libghostty.sh --target universal --release
bash scripts/build-libghostty.sh --print-path
bash scripts/build-libghostty.sh --print-resources-path
```

Typical local build flow:

```bash
brew install zig@0.15 xcodegen swift-format
xcodebuild -downloadComponent MetalToolchain
git submodule update --init --recursive third_party/ghostty
bash scripts/build-libghostty.sh
bash scripts/dev-argon.sh .
```

That final command builds the Rust CLI, regenerates the Xcode project,
builds `Argon.app`, and launches the requested workspace.

Expected outputs:

- `target/libghostty/<target>/macos/GhosttyKit.xcframework`
- `target/libghostty/<target>/share/ghostty`

## Current State

- Ghostty is the in-app terminal renderer for shell, agent, and reviewer
  tabs.
- Argon still owns command construction, environment shaping, sandboxing,
  terminal tab lifecycle, and review metadata.
- The embedded terminal intentionally strips inherited terminal identity
  from the parent app process before launch, then lets Ghostty populate its
  own runtime terminal variables for the child shell.
- User Ghostty configuration files are still loaded, so fonts, themes,
  keybindings, and other appearance settings continue to apply.

## Open Questions

- Whether the bundled Ghostty resource set can be reduced safely for Argon's
  embedded use case.
- Whether local developer builds should remain host-native while release
  asset builds produce universal Ghostty artifacts.
