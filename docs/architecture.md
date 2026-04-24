# Architecture And Repo Layout

This document is a technical overview of the Argon repository.

For the product overview, start with the [README](../README.md).

## Source Of Truth

- Product requirements: [PRD.md](../PRD.md)
- Agent review contract:
  [skills/argon-app-review/SKILL.md](../skills/argon-app-review/SKILL.md)

If behavior conflicts, prioritize the PRD and update the other docs.

## Repository Layout

```text
argon/
├── apps/
│   └── macos/            # SwiftUI app
├── crates/
│   ├── argon/            # CLI binary
│   ├── argon-core/       # Shared domain types and review backend traits
│   └── sandbox/          # Sandbox evaluation and macOS backend
├── docs/                 # Technical and contributor docs
├── scripts/              # Build, dev, and screenshot helpers
├── skills/               # Bundled optional agent skills
├── third_party/ghostty/  # Vendored Ghostty dependency
├── Cargo.toml            # Rust workspace root
├── Makefile              # Common build/test/check entry points
└── PRD.md                # Product requirements
```

## Main Pieces

### `apps/macos`

The native macOS app. It is primarily SwiftUI, with AppKit used where the
platform requires lower-level integration such as text editing and PTY
terminal hosting.

### `crates/argon-core`

Shared domain logic:

- review session types
- diff and comment models
- backend traits
- machine-readable agent control contracts

### `crates/argon`

The bundled `argon` CLI used for:

- human launch commands such as `argon <dir>`
- standalone review launch
- machine-readable review and agent workflows
- sandbox inspection and execution

### `crates/sandbox`

Sandbox evaluation and enforcement abstraction.

Today it ships with a macOS backend and a `Sandboxfile` policy language
covering filesystem, execution, environment, and network behavior.

### `skills/`

Bundled optional skills that wrap Argon’s review flow for agents that can
consume skills. They are convenience wrappers, not the only supported
integration path.

## Key Design Decisions

- SwiftUI first. Use AppKit only for hard platform limitations.
- One repository per workspace window.
- One review window per review session.
- Prompt-first agent handoff remains a first-class path.
- The CLI stays machine-readable first.
- Draft review mode accumulates comments until submission.
- Diff refresh is automatic through filesystem watching.

## Related Docs

- [Development and contributing](development.md)
- [Ghostty integration notes](ghostty-integration.md)
- [Sandbox reference](../SANDBOX.md)
