# Architecture And Repo Layout

This document is a technical overview of the Argon repository.

For the product overview, start with the [README](../README.md).

## Source Of Truth

- Product requirements: [PRD.md](../PRD.md)
- CLI protocol contract: [protocol.rs](../crates/argon-core/src/protocol.rs)
- Prompt contract: [prompt.rs](../crates/argon-core/src/prompt.rs)

If behavior conflicts, prioritize the PRD and update the other docs.

## Repository Layout

```text
argon/
├── apps/
│   └── macos/            # SwiftUI app
├── crates/
│   ├── argon/            # CLI binary
│   ├── argon-core/       # Shared domain types, review logic, and protocols
│   ├── argon-lib/        # FFI bridge used by the macOS app
│   └── sandbox/          # Sandbox evaluation and macOS backend
├── docs/                 # Technical and contributor docs
├── scripts/              # Build, dev, and screenshot helpers
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

View files should stay organized by UI surface rather than accumulating into
large window files. Root views own orchestration and environment wiring;
focused files own sidebar, terminal, inspector, review, agent launch, and
shared control surfaces. Presentation-only helpers may live beside the view
that uses them; reusable state and behavior should move into `Models/` or
`Services/`.

The workspace window currently follows this split:

- `WorkspaceWindowView.swift`: window shell, workspace-level sheets, alerts,
  and review/finalize orchestration.
- `WorkspaceSidebarViews.swift`: worktree list rows, metadata, and row
  actions.
- `WorkspaceCenterViews.swift`: center pane, toolbar items, and changed-file
  panel.
- `WorkspaceTerminalChromeViews.swift`: terminal deck, tab chrome, restore
  menu, and status pills.
- `WorkspaceTerminalStageViews.swift`: hosted terminal stage and empty/exited
  terminal states.
- `WorkspaceReviewViews.swift`: review preparation and review inspector UI.
- `WorkspaceAgentSheetViews.swift`: agent launch and new-worktree sheets.
- `WorkspaceInspectorViews.swift`: right inspector and sandbox network
  activity UI.
- `WorkspaceSharedViews.swift`: shared workspace surfaces, badges, diff
  summaries, editor launcher, and worktree removal controls.

Workspace state is split by workflow while keeping one observable
`WorkspaceState` instance per window:

- `WorkspaceState.swift`: stored state, lifecycle observers, and simple
  selection/window computed properties.
- `WorkspaceState+Worktrees.swift`: worktree inventory, diff-mode selection,
  detail loading, filesystem watching, refreshes, and removal requests.
- `WorkspaceState+TerminalTabs.swift`: shell/agent tab creation, terminal
  selection, attention state, exit handling, and UI-test demo tab seeding.
- `WorkspaceState+Persistence.swift`: persisted window snapshots, lazy tab
  restoration, background agent restore metadata, and resumable sessions.
- `WorkspaceState+ReviewFlow.swift`: review preparation, finalize flows,
  agent control requests, and staged review launch handoff.

### `crates/argon-core`

Shared domain logic:

- review session types
- diff and comment models
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

## Key Design Decisions

- SwiftUI first. Use AppKit only for hard platform limitations.
- One repository per workspace window.
- One review window per review session.
- App/CLI-driven agent handoff remains the first-class path.
- The CLI stays machine-readable first.
- Draft review mode accumulates comments until submission.
- Diff refresh is automatic through filesystem watching.
- Refactors should preserve behavior and improve ownership boundaries. Avoid
  mixing feature work with structural cleanup unless the behavior change
  requires the refactor.

## Related Docs

- [Development and contributing](development.md)
- [Ghostty integration notes](ghostty-integration.md)
- [Sandbox reference](../SANDBOX.md)
