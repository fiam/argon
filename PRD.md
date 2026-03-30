# Argon — PRD

## 1. Problem Statement

Coding agents are fast, but humans need to coordinate them: launch tasks,
watch progress, review output, provide feedback, and approve results. Today
this requires juggling multiple terminals, manually creating worktrees, and
context-switching between agent output and review UIs.

Argon is a **native macOS workspace for coordinating coding agents**. It
gives the human a single window per project to:

- See all active worktrees and the agents working in them.
- Launch new agent tasks into isolated worktrees.
- Watch agent progress in embedded terminals.
- Review diffs with GitHub-style inline commenting.
- Approve, request changes, or delegate review to other agents.

## 2. Vision

A native macOS app that is the human's command center for agent-assisted
development:

- **One window per project** — shows the repo, its worktrees, and running
  agents.
- **Launch agents** — pick an agent (Claude Code, Codex, Gemini, custom),
  write a prompt, and spin up a new worktree with the agent running in it.
- **Embedded terminals** — watch agent output live via libghostty.
- **Built-in review** — when an agent is ready for review (or the human
  wants to inspect), open a full diff review UI with inline comments,
  thread replies, draft batching, and approval.
- **Agent-agnostic** — works with any CLI agent via skills. The review
  loop is also accessible standalone from any agent outside the app.
- **Shared Rust core** — all domain logic, git integration, session
  management, and syntax highlighting in a portable Rust library.

## 3. Goals

- Sub-second cold launch to project view.
- Native text rendering, syntax highlighting (syntect + two-face), and
  smooth scroll for diffs.
- Support both **app-driven** (user launches from Argon) and
  **CLI-driven** (agent triggers review via skill) workflows.
- Ship a single self-contained `.app` bundle with embedded CLI.
- Keep the CLI contract stable so existing agent skills work unchanged.
- Architect for future platform UIs (Linux, Windows) without forking
  the core.

## 4. Non-Goals (current phase)

- Linux or Windows native UI (core compiles cross-platform; UI is
  macOS-only for now).
- GitHub PR sync.
- Remote/SaaS mode (deferred — the `ReviewBackend` trait preserves the
  option but we focus on local-first).
- Mobile access.

## 5. Primary Users

- **Developer (human)**: opens a project, launches agent tasks into
  worktrees, watches progress, reviews diffs, approves or requests
  changes. Coordinates multiple agents simultaneously.
- **Coding agent**: works in a worktree, triggers review via CLI skill,
  blocks for feedback, applies fixes, and waits for approval.
- **Reviewer agent**: launched by the human (from the app or CLI) to
  perform focused reviews. Posts comments but cannot give final approval.

## 6. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        macOS App (SwiftUI)                           │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  Project Window (one per repo)                                 │  │
│  │  ┌──────────┐  ┌────────────────────┐  ┌───────────────────┐  │  │
│  │  │ Worktree │  │ Terminal           │  │ Review Summary    │  │  │
│  │  │ Sidebar  │  │ (libghostty)       │  │ / Inspector       │  │  │
│  │  │          │  │                    │  │                   │  │  │
│  │  │ main     │  │ $ claude ...       │  │ 3 threads open    │  │  │
│  │  │ ├ wt-1 ◉│  │ Working on task... │  │ +42 -8            │  │  │
│  │  │ ├ wt-2 ◎│  │                    │  │ [Review →]        │  │  │
│  │  │ └ wt-3 ✓│  │                    │  │                   │  │  │
│  │  └──────────┘  └────────────────────┘  └───────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  Review Window (opens from project window or CLI skill)              │
│  ┌──────────┐  ┌──────────────────────────┐  ┌───────────────────┐  │
│  │ File     │  │ Diff View (unified/sbs)  │  │ Threads           │  │
│  │ Tree     │  │ syntax highlighted       │  │ Inspector         │  │
│  │ + filter │  │ word-level changes       │  │                   │  │
│  └──────────┘  └──────────────────────────┘  └───────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              │      argon-core (Rust)  │
              │  sessions · worktrees   │
              │  diffs · highlighting   │
              │  git · storage · CLI    │
              └─────────────────────────┘
```

### 6.1 Window Model

- **Project Window**: one per repo/directory. Shows worktrees, running
  agents, and a summary of active reviews. The main daily-driver view.
- **Review Window**: the full diff review UI. Opens when clicking
  "Review" on a worktree, or when an agent triggers a review via CLI
  skill. Can exist standalone (current behavior) or be launched from
  a project window.

### 6.2 Rust Workspace

```
argon-native/
├── crates/
│   ├── argon-core/       # Domain types, ReviewBackend trait, LocalBackend,
│   │                     # diff engine, syntax highlighting, git adapter
│   ├── argon/            # CLI binary
│   └── argon-ipc/        # IPC server (future)
├── apps/
│   └── macos/            # SwiftUI app (project.yml, .xcodeproj gitignored)
│       ├── Sources/
│       └── Tests/
├── skills/               # Bundled agent skills
├── scripts/              # Dev scripts
├── Makefile              # make check, make fmt, make test
├── deny.toml             # cargo-deny config
└── Cargo.toml            # Workspace root
```

| Crate | Role |
|---|---|
| `argon-core` | Domain types, `ReviewBackend` trait, `LocalBackend`, diff engine, syntax highlighting (syntect + two-face), git adapter. Platform-agnostic. |
| `argon` | CLI binary. All agent/reviewer/draft/diff commands. |
| `argon-ipc` | Future: IPC server for native UI ↔ core communication. |

### 6.3 The `ReviewBackend` Trait

Per-session abstraction. Each review window holds one backend. The trait
defines session lifecycle, comments, threads, decisions, diffs, and
reactive watch. `LocalBackend` is the only implementation for now.

### 6.4 Project Configuration

Each project directory can have an `.argon/config.toml`:

```toml
[project]
name = "my-service"

[agents]
default = "claude"  # claude | codex | gemini | custom

[agents.claude]
command = "claude --dangerously-skip-permissions"
sandbox = false

[agents.codex]
command = "codex --yolo"
sandbox = false

[agents.custom]
command = "./scripts/my-agent.sh"
sandbox = true

[worktree]
auto_cleanup = true      # remove worktree after merge/close
base_branch = "main"
```

When no config exists, the app uses sensible defaults (auto-detect
available agents, no sandboxing).

### 6.5 Worktree Management

- Each agent task runs in a **git worktree** — an isolated working
  copy that shares the repo's object store.
- The app creates worktrees via `git worktree add`, launches the
  agent in the worktree directory, and tracks its lifecycle.
- Worktree states: `creating`, `running` (agent active), `awaiting_review`,
  `approved`, `closed`.
- On approval, the worktree's branch can be merged or a PR created.
- On close, the worktree is cleaned up (if `auto_cleanup` is on).

### 6.6 Terminal Embedding (libghostty)

- Embed [libghostty](https://github.com/ghostty-org/ghostty) for
  terminal rendering — the same engine as Ghostty terminal.
- Each running agent gets a terminal tab/panel in the project window.
- The terminal shows live agent output (stdout/stderr).
- The human can interact with the terminal if needed (e.g. to answer
  agent prompts).

### 6.7 Agent Launch Flow

1. Human opens project window (or `argon open .` from terminal).
2. Clicks "New Task" → picks agent, writes prompt, optionally configures
   sandbox/YOLO mode.
3. Argon creates a new worktree from the base branch.
4. Argon launches the agent in the worktree with the prompt.
5. The agent works, optionally triggers a review via `argon agent start`.
6. The project window shows the worktree as "awaiting review".
7. Human clicks "Review" → opens the review window for that worktree.
8. Review loop proceeds (comments, replies, approve/close).
9. On approval, Argon can merge the worktree branch.

### 6.8 Standalone Review (current behavior)

The review UI also works standalone, triggered by any agent from any
terminal:

```bash
argon agent start --repo <dir> --mode <mode> --description "..." --wait --json
```

This opens a review window without a project window. The full CLI
contract is preserved — existing skills continue to work.

### 6.9 Storage

- JSON file store under `~/.cache/argon/` (current implementation).
- Session, thread, comment, and draft data per repo.
- Project config in `.argon/config.toml` per repo.
- Worktree state tracked alongside sessions.

### 6.10 Git Integration

- Shell out to `git` for diff, merge-base, worktree management.
- Isolate behind a `GitAdapter` trait so tests can use fixtures.
- Support branch, commit, and uncommitted review modes.

## 7. Skill-Oriented Design

Argon is **skill-driven**: agents interact via CLI, the app is the
human's surface. This works for both app-launched agents (in worktrees)
and external agents (triggered from any terminal).

### 7.1 Coder Agent Skill

The skill defines the full review lifecycle:

1. `argon agent start --repo <dir> --mode <mode> --description "..." --wait --json`
2. Acknowledge → implement → reply → re-wait until `approved` or `closed`.
3. On approval: commit. On close: stop without committing.

### 7.2 Skill Auto-Install

- The bundled `.app` ships skills at `Argon.app/Contents/Resources/skills/`.
- On first launch, auto-installs into detected agent skill homes.
- CLI: `argon skill install [--agent <claude-code|codex|all>]`.

### 7.3 Reviewer Agent Launch

From the project window or review window, the human can launch reviewer
agents:

- **Agent picker**: detects available agents.
- **Focus prompt**: optional review scoping instructions.
- **Terminal**: agent runs in an embedded terminal.
- **Contract**: reviewer agents can inspect and test but cannot edit
  files or approve — only the human can approve.

## 8. Data Model

### Review (existing)

- **ReviewSession** — id, repo_root, mode, base_ref, head_ref,
  change_summary, status, timestamps.
- **ReviewThread** — id, state (open/addressed/resolved), comments.
- **ReviewComment** — id, author, kind, anchor, body, timestamp.
- **ReviewDecision** — outcome, summary, timestamp.
- **DraftReview** — batched comments before submission.

### Workspace (new)

- **Project** — repo_root, config, list of worktrees.
- **Worktree** — id, branch, path, agent_command, status
  (creating/running/awaiting_review/approved/closed), session_id
  (links to ReviewSession when in review), created_at.
- **AgentProfile** — name, command, sandbox config, detected/custom.

## 9. CLI Contract

Existing commands preserved. New additions for workspace management:

```
# Existing (review)
argon .
argon review --repo <dir> --mode <mode> [flags]
argon agent start|wait|follow|status|close|ack|reply|prompt [flags]
argon reviewer prompt|wait|comment|decide [flags]
argon draft add|delete|list|submit [flags]
argon diff --session <id> --theme <theme> --json
argon skill install [--agent <name>]

# New (workspace)
argon open <dir>                      # open project window
argon worktree create --prompt "..."  # create worktree + launch agent
argon worktree list --json            # list worktrees
argon worktree status <id> --json     # worktree status
argon worktree close <id>             # close and cleanup
```

## 10. macOS UI Requirements

### 10.1 Project Window

- **Worktree sidebar**: list of worktrees with status icons
  (running ◉, awaiting review ◎, approved ✓, closed ✗).
- **Terminal panel**: embedded libghostty terminal showing the
  selected worktree's agent output.
- **Review summary**: right inspector showing active review
  threads, diff stats, and a "Review →" button.
- **New Task button**: opens agent picker + prompt input.
- **Project config**: accessible via toolbar or menu.

### 10.2 Review Window (existing, polished)

- File tree sidebar with fuzzy/glob/regex filtering.
- Unified and side-by-side diff views with syntax highlighting.
- Word-level change highlighting within modified lines.
- Inline comment editor, draft review batching.
- Thread replies and resolve from the UI.
- Orphaned thread handling for files that left the diff.
- Live diff refresh via FSEvents.
- Search across diff content with match navigation.
- Keyboard shortcuts (⌘F search, ⌘↑/↓ file nav, ⌘1/2 view mode).
- Rolling number animations on diffstat changes.

### 10.3 Notifications

- macOS native notifications when a worktree reaches
  `awaiting_review` or when an agent replies to review feedback.

## 11. UX Principles

- **Fast open**: project view within 1 second of launch.
- **Clear status**: always show what each worktree/agent is doing.
- **Minimal friction**: keyboard-first, single-action approve/launch.
- **Traceability**: every thread shows author, timestamps, state.
- **Native feel**: standard macOS chrome, libghostty terminals.
- **Agent-agnostic**: works with any CLI agent, no lock-in.

## 12. Milestones

### M1 — Rust Core + CLI + Skill Install ✅

- argon-core with domain types, storage, diff, git integration.
- Full CLI with agent/reviewer/draft/diff commands.
- Skill auto-install.

### M2 — macOS Diff Viewer ✅

- SwiftUI app with file tree, diff rendering, session loading.
- CLI-driven launch (`argon .` opens app).

### M3 — Review Loop ✅

- Inline comments, draft review batching, decisions.
- Thread replies and resolve.
- Session polling, close-on-exit, agent handoff.
- Mode selector (branch/commit/uncommitted).

### M4 — Live Updates + Polish ✅

- FSEvents file watcher, live diff refresh.
- Syntax highlighting (syntect + two-face).
- Word-level diff highlighting.
- Unified/side-by-side toggle.
- File tree with fuzzy/glob/regex filter.
- Search across diff content.
- Keyboard shortcuts and menu items.
- Rolling number animations.

### M5 — Bundled App

- Embed `argon` CLI in `Argon.app/Contents/Resources/bin/argon`.
- `make package` target for distributable `.app`.
- Skill auto-install on first launch.
- URL scheme: `argon://session/<id>`.

### M6 — Project Window

- Window-per-directory project view.
- Worktree sidebar with status tracking.
- Project config (`.argon/config.toml`).
- "New Task" flow: pick agent, write prompt, create worktree.
- Review summary inspector.

### M7 — Terminal Embedding

- libghostty integration for terminal rendering.
- Terminal panel in project window per worktree.
- Agent launch into terminal with prompt.
- Interactive terminal support (human can type).

### M8 — Agent Orchestration

- Agent picker with detected profiles (Claude Code, Codex, Gemini).
- Sandbox/YOLO mode toggle per agent launch.
- Worktree lifecycle: create → agent runs → review → approve → merge.
- Reviewer agent launch from review window.
- Multiple concurrent agents per project.

## 13. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| libghostty integration complexity | Start with a simple PTY wrapper; upgrade to libghostty incrementally. |
| Worktree management edge cases | Git worktrees are well-tested; add cleanup on close and conflict detection. |
| Terminal performance in SwiftUI | Use NSViewRepresentable for the terminal; SwiftUI for chrome. |
| Agent diversity (different CLIs) | Abstract via command template + env vars; test with Claude Code, Codex, and a shell script. |
| Diff rendering for large repos | Stream hunks lazily; fingerprint-based refresh avoids unnecessary re-parses. |

## 14. Open Questions

- libghostty licensing and embedding story — is it available as a library?
- Should worktree branches auto-name (e.g. `argon/task-<id>`) or let
  the user choose?
- Merge strategy on approval: squash merge, regular merge, or just
  leave the branch for the user to merge?
- Should the project window show a combined diff across all worktrees,
  or only per-worktree?
- Agent sandboxing: Docker, macOS sandbox, or just file system
  permissions?
