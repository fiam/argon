# Argon Native — PRD

## 1. Problem Statement

Coding agents can make fast changes, but the review and approval loop is the
bottleneck. The Tauri prototype validates the local review loop, but the
web-view stack adds weight, startup latency, and limits platform integration.
A native rewrite delivers a faster, more integrated experience while keeping
the agent-facing CLI contract stable and the architecture open to future
remote/SaaS operation.

## 2. Vision

Rebuild Argon with:

- A **shared Rust core** containing all domain logic, session management, CLI,
  and Git integration.
- **Per-platform native UIs** (macOS first, SwiftUI primary with AppKit where
  needed) that feel like first-class OS citizens.
- A **CLI-launchable workflow** (`argon .`, `argon review ...`) so agents and
  humans can open the review UI from the terminal — the same way `code .`
  launches VS Code.
- A **clean backend abstraction** (`ReviewBackend` trait) so the same app and
  CLI can later connect to a remote coordinator service for SaaS/cloud
  operation.

## 3. Goals

- Preserve the full agent ↔ reviewer loop from the Tauri prototype.
- Achieve sub-second cold launch to diff view.
- Use native text rendering, syntax highlighting, and scroll for diffs.
- Support CLI-driven launch: `argon .` opens the native app with a new session.
- Keep the CLI contract identical so existing skills work unchanged.
- Ship a single self-contained app bundle (macOS `.app`) that includes the
  `argon` CLI binary.
- Architect for future platform UIs (Linux, Windows) without forking the core.

## 4. Non-Goals (v1)

- Linux or Windows native UI (core compiles cross-platform; UI is macOS-only
  for now).
- GitHub PR sync.

## 5. Primary Users

- **Human reviewer**: inspects diffs, leaves line/global comments, approves or
  requests changes. Can also delegate partial review to reviewer agents.
- **Coding agent**: starts a session via skill, blocks for feedback, applies
  fixes, replies, and waits for re-review.
- **Reviewer agent**: launched by the human (from the app or remotely) to
  perform focused or supplementary reviews (e.g. "check error handling",
  "review test coverage"). Posts comments but cannot give final approval.
- **Mobile reviewer** (future): triages sessions, reads diffs, launches
  reviewer agents, and approves from a phone.

## 6. Architecture

The central design principle is a **backend trait** that abstracts all
session and review operations behind a common interface. The native app and
CLI program against this trait. We ship a local implementation first; the
same trait gets a remote implementation later to support SaaS/cloud mode.

```
┌───────────────────────────────────────────────────────────────────┐
│                        macOS App (SwiftUI)                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │  Window A        │  │  Window B        │  │  Window C        │  │
│  │  LocalBackend    │  │  RemoteBackend   │  │  RemoteBackend   │  │
│  │  (local session) │  │  (cloud proj 1)  │  │  (cloud proj 2)  │  │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘  │
└───────────┼─────────────────────┼─────────────────────┼──────────┘
            │ IPC                  │ HTTPS/WSS           │ HTTPS/WSS
    ┌───────┴───────┐     ┌───────┴──────┐      ┌───────┴──────┐
    │ argon-core    │     │ coordinator  │      │ coordinator  │
    │ (local)       │     │ (project 1)  │      │ (project 2)  │
    └───────────────┘     └──────────────┘      └──────────────┘
```

**Backends are per-session, and each session maps to one app window.** A
single running app can have windows backed by different `ReviewBackend`
implementations simultaneously — e.g. one local session and two remote
sessions pointing at different cloud projects. The window doesn't know or
care which backend type it's using; it programs against the trait.

### 6.1 The `ReviewBackend` Trait

The trait is the load-bearing abstraction. A backend instance is created
**per session** — each app window holds exactly one backend, and that
backend manages one session's lifecycle. The trait defines every operation
the window needs:

```rust
trait ReviewBackend {
    // Session lifecycle
    fn create_session(&self, opts: CreateSessionOpts) -> Result<ReviewSession>;
    fn get_session(&self, id: SessionId) -> Result<ReviewSession>;
    fn close_session(&self, id: SessionId) -> Result<()>;

    // Comments and threads
    fn add_comment(&self, comment: NewComment) -> Result<ReviewComment>;
    fn ack_thread(&self, session: SessionId, thread: ThreadId) -> Result<()>;
    fn reply_thread(&self, reply: ThreadReply) -> Result<ReviewComment>;

    // Decisions
    fn submit_decision(&self, decision: NewDecision) -> Result<ReviewDecision>;

    // Diffs
    fn get_diff(&self, session: SessionId) -> Result<DiffData>;

    // Reactive
    fn watch(&self, session: SessionId) -> Result<impl Stream<Item = SessionEvent>>;
}
```

**`LocalBackend`** (ships in M1): SQLite storage, shells out to `git`,
`notify`-based file watcher. This is the only implementation we build
initially.

**`RemoteBackend`** (future SaaS): same trait, backed by HTTPS/WSS calls
to the coordinator service. The app and CLI don't know the difference.

### 6.2 Monorepo Structure

Everything lives in one repository:

```
argon-native/
├── crates/
│   ├── argon-core/       # Domain types, ReviewBackend trait, LocalBackend
│   ├── argon/            # CLI binary
│   └── argon-ipc/        # IPC server (Unix socket, JSON protocol)
├── apps/
│   └── macos/            # SwiftUI app (project.yml + sources, .xcodeproj gitignored)
├── skills/               # Bundled agent skills
│   ├── argon-app-review/
│   └── argon-dev-review/
└── Cargo.toml            # Workspace root
```

Future additions (`coordinator/`, `mobile/`) will live at the repo root
when those milestones begin.

| Crate | Role |
|---|---|
| `argon-core` | Domain types, `ReviewBackend` trait, `LocalBackend`, diff engine, Git adapter. Platform-agnostic. |
| `argon` | CLI binary. Depends on `argon-core`. |
| `argon-ipc` | IPC server (Unix domain socket) exposing `ReviewBackend` operations to native UI processes. Length-prefixed JSON. |

### 6.3 Native UI (macOS)

- SwiftUI app under `apps/macos/`.
- **XcodeGen** for project generation — the `project.yml` is checked in,
  `.xcodeproj` is gitignored. Run `xcodegen` to regenerate after changing
  project structure.
- Connects to the Rust core via the IPC socket. The IPC layer exposes
  `ReviewBackend` operations — the app doesn't know whether the backend is
  local or remote.
- Receives diff data, session state, and file-watcher events over the socket.
- Sends comments, decisions, and navigation commands back.
- **SwiftUI-primary**: use SwiftUI for all UI (toolbar, sidebar, status, lists,
  controls). Drop to AppKit only when SwiftUI has a hard limitation (e.g.
  NSTextView for high-performance syntax-highlighted diff scrolling, or
  NSViewRepresentable wrappers for terminal embedding).

### 6.4 CLI ↔ App Launch Protocol

Each session gets its own window. Multiple `argon .` invocations open
multiple windows in the same app process.

1. `argon .` (or `argon review ...`) creates a session in the local store,
   starts the IPC server if not already running, and launches the app via
   `open -a Argon --args --session <id> --ipc <socket-path>`.
2. The app opens a new window, creates a `LocalBackend` for that session,
   connects to the IPC socket, and renders the diff.
3. If the app is launched directly (from Dock / Spotlight), it presents an
   open/create session flow, then opens a window with the appropriate backend.
4. Closing a window marks that window's session `closed`. Other windows are
   unaffected.

The bundled app ships the CLI at `Argon.app/Contents/Resources/bin/argon` so
the full loop works from a single download.

### 6.4 Storage

- Local SQLite database under `~/.cache/argon/sessions/<repo-key>/` (or
  `$XDG_CACHE_HOME`), same layout as the Tauri prototype.
- Write-ahead logging enabled so CLI and app can access concurrently.

### 6.5 Git Integration

- Shell out to `git` for diff, merge-base, branch metadata.
- Isolate behind a `GitAdapter` trait so tests can use fixtures.

### 6.6 Remote / SaaS Mode (future — `RemoteBackend`)

Cloud mode is not a separate architecture — it's a second implementation of
`ReviewBackend` plus a coordinator service. The details (sandbox
provisioning, container runtime, mobile client) are deferred. What matters
now is that the `ReviewBackend` trait is clean enough that a `RemoteBackend`
backed by HTTPS/WSS can be dropped in later without touching the CLI, IPC
layer, or UI.

## 7. Skill-Oriented Design

Argon is designed as a **skill-driven tool**: agents interact with it
exclusively through the CLI, and the app is the surface where humans
orchestrate the review — including launching additional agents.

### 7.1 Coder Agent Skill (entry point)

A coding agent triggers the review loop via a bundled skill
(`argon-app-review`). The skill defines the full lifecycle:

**1. Start a session and open the review UI:**

```bash
argon agent start --repo <directory> --mode <branch|commit|uncommitted> \
  [--base <branch>] [--head <branch>] [--commit <sha>] \
  --description "..." --wait --json
```

The agent **must** provide:
- `--repo <directory>` — the working directory to review.
- `--mode` — one of:
  - `branch` — diff from merge-base of `--base` to working tree.
  - `commit` — diff from `--commit` (default `HEAD`) to working tree.
  - `uncommitted` — `HEAD` to working tree (staged + unstaged only).

`--wait` blocks until the reviewer submits feedback or a decision. The
command returns a JSON payload with the session state, threads, and
decision.

**2. Handle feedback — acknowledge, implement, reply:**

```bash
# Acknowledge a thread before starting work on it
argon agent ack --session <id> --thread <id> --json

# After implementing the fix, reply with what changed
argon agent reply --session <id> --thread <id> \
  --message "Fixed: refactored error handling in parse()" --addressed
```

The agent should acknowledge each open thread, implement the requested
change, then reply with a concrete description of what it did. The
`--addressed` flag marks the thread as handled from the agent's side.

**3. Await re-review:**

```bash
argon agent wait --session <id> --json
```

Blocks until the reviewer responds again. Returns the same JSON structure
as `start --wait`. The agent **must keep looping** steps 2-3 until the
session reaches a terminal state.

**4. Terminal states — the skill must instruct the agent:**

- **`approved`**: the reviewer has approved and expects the agent to commit.
  The agent should create a commit (or whatever finalization the reviewer
  requested) and then stop.
- **`closed`**: the reviewer closed the window / cancelled the session. The
  agent must stop immediately — no commit, no further changes.
- Any other state (`changes_requested`, `commented`, `awaiting_reviewer`):
  keep looping. Never give up or stop polling while the session is still
  active.

The skill prompt must be explicit: *"Keep waiting for reviewer feedback
until the session is approved or closed. Do not stop early. On approval,
commit your changes. On close, stop without committing."*

**5. Check status without blocking:**

```bash
argon agent status --session <id> --json
```

**6. Close a session explicitly (if needed):**

```bash
argon agent close --session <id> --json
```

The skill is the **only contract** between the coding agent and Argon. The
agent never needs to know about the UI, IPC, or internal state — it talks
CLI and gets structured JSON back.

### 7.2 Skill Auto-Install (day 1)

Skill distribution is a **day-1 requirement**, not a polish item. If the
skill isn't installed, agents can't trigger review loops — the whole product
is inert.

- The bundled `.app` ships skills at
  `Argon.app/Contents/Resources/skills/`.
- On first launch (and on update), the app detects local skill homes
  (Claude Code `~/.claude/skills`, Codex `~/.codex/skills`) and
  installs/updates the bundled `argon-app-review` skill automatically.
- The CLI also supports `argon skill install` for headless environments
  (CI, cloud sandboxes) where the app may not be present.
- A "Reveal Skill" action in the app exposes the raw skill directory for
  manual installation into other agent frameworks.

### 7.3 Reviewer Agent Launch (deferred to M5)

The human reviewer can launch one or more reviewer agents directly from
the app UI to perform focused or supplementary reviews. This is a
first-class workflow but requires the embedded terminal infrastructure,
so it ships after the core review loop is solid.

- **Agent picker**: detects locally available agents (Claude Code, Codex,
  custom commands).
- **Focus prompt**: optional scoping instructions (e.g. "check error
  handling", "verify test coverage for public APIs").
- **Multiple concurrent agents**: each gets a nickname, runs in the same
  repo directory, and posts findings via `argon reviewer comment ...`.
- **Contract**: reviewer agents can inspect and test but **cannot edit
  files** or give final `approved` — only the human can approve.

## 8. Data Model

Carried over from the Tauri prototype unchanged:

- **ReviewSession** — id, repo_root, mode (`branch`/`commit`/`uncommitted`),
  base_ref, head_ref, change_summary, status, timestamps.
- **ReviewThread** — id, state (open/addressed/resolved),
  agent_acknowledged_at, comments.
- **ReviewComment** — id, session_id, author, author_name, kind, file_path,
  line_new, line_old, body, thread_id, timestamp.
- **ReviewDecision** — session_id, outcome, summary, timestamp.

Session statuses: `awaiting_reviewer`, `awaiting_agent`, `approved`, `closed`.

## 9. CLI Contract

Based on the Tauri prototype with one key addition: the `uncommitted` review
mode. All existing commands, flags, JSON schemas, and exit codes are
preserved.

Key commands:

```
argon .
argon review --repo <dir> --mode <branch|commit|uncommitted> [flags]
argon agent start --repo <dir> --mode <branch|commit|uncommitted> [flags]
argon agent wait|follow|status|close|ack|reply|prompt [flags]
argon reviewer prompt|wait|comment|decide [flags]
argon skill install [--agent <claude-code|codex|all>]
```

Review modes:

- `branch` — merge-base of `--base` to working tree (requires `--base`,
  optional `--head`).
- `commit` — `--commit` (default `HEAD`) to working tree.
- `uncommitted` — `HEAD` to working tree (staged + unstaged changes only).

Global flags: `--repo`, `--desktop-launch`, `--agent`, `--description`,
`--json`.

## 10. macOS UI Requirements

### 10.1 Diff View

- File tree sidebar (changed files grouped by directory).
- Split or unified diff pane with syntax-highlighted hunks.
- Line-level comment gutters (click to add, inline thread display).
- Global comment panel.

### 10.2 Review Controls

- Toolbar buttons: **Approve**, **Request Changes**, **Comment**.
- Session status badge: shows current state and who is being waited on.
- Copy-friendly agent handoff command.
- Change summary display when `--description` was provided.

### 10.3 Reviewer Agent Launch (M5)

- **Launch menu** in the toolbar or sidebar: lists detected agents with
  preset profiles (e.g. "Claude Code", "Claude Code (YOLO)", "Codex",
  "Custom command…").
- **Focus prompt field**: optional text input shown before launch — the
  reviewer types a focus area (e.g. "check error handling in the new
  parser", "verify test coverage for public APIs") or leaves blank for
  general review.
- **Agent terminal tabs**: each running reviewer agent gets a tab in a
  bottom/side panel. The tab shows the agent's nickname, status (running /
  done), and a live terminal view (AppKit `NSViewRepresentable` wrapping a
  PTY-backed terminal emulator).
- **Multiple agents**: the reviewer can launch several agents with different
  focus prompts simultaneously. Each operates independently on the same
  session.

### 10.4 Live Updates

- File watcher on the working tree; refresh diff without losing scroll or
  comment context.
- Mark threads as potentially stale when target lines move.

### 10.5 Notifications

- macOS native notifications (via `UNUserNotificationCenter`) when a session
  transitions to `awaiting_reviewer`.
- Notification includes session summary and a deep-link action to open the
  session directly.
- Future: push notifications to phone in remote/SaaS mode.

### 10.6 Platform Integration

- `argon` CLI registered via shell PATH (symlink or `argon shell-integration`).
- Supports `open argon://session/<id>` URL scheme for deep links.
- Respects system appearance (light/dark).
- Native keyboard shortcuts (⌘-Enter to submit comment, etc.).

## 11. IPC Protocol

- Transport: Unix domain socket at a well-known path
  (`$TMPDIR/argon-<uid>/ipc.sock`).
- Framing: length-prefixed JSON messages (4-byte big-endian length + UTF-8
  JSON payload).
- Patterns:
  - **Request/response** — CLI or app sends a request, core replies.
  - **Server-push** — core pushes file-watcher diffs and session state changes.
- The IPC server is embedded in the CLI process (when launched via `argon .`)
  or in the app process (when launched standalone).

## 12. UX Principles

- **Fast open**: diff visible within 1 second of launch.
- **Clear status**: always show who the session is waiting on.
- **Minimal friction**: keyboard-first review, single-action approve/request.
- **Traceability**: every thread shows author, timestamps, and state.
- **Native feel**: standard macOS chrome, no web-view seams.

## 13. Milestones

### M1 — Rust Core + CLI + Skill Install

- Port `argon-core` and `argon` CLI from the Tauri workspace.
- Add `argon-ipc` crate with socket server and JSON protocol.
- All existing CLI commands work identically.
- Storage is compatible with the Tauri prototype.
- `argon skill install` works for headless environments.
- Bundled skill auto-installs into detected agent skill homes.

### M2 — macOS Diff Viewer (read-only)

- Swift app connects to IPC, renders file tree and diff.
- `argon .` launches the app and loads the session.
- Skill auto-install on first app launch.
- No commenting yet — read-only diff inspection.

### M3 — Review Loop

- Line and global comments in the native UI.
- Review decision controls (approve / request changes / comment).
- Agent handoff command display.
- Full round-trip: agent starts → reviewer comments → agent replies → approval.
- OS notifications when session reaches `awaiting_reviewer`.

### M4 — Live Updates + Polish

- File watcher integration; diff refreshes without losing context.
- Stale-thread detection after line shifts.
- System appearance support, keyboard shortcuts, URL scheme.
- Bundled `.app` with embedded CLI.

### M5 — Reviewer Agent Launch

- Reviewer agent launch menu with detected agent profiles.
- Focus prompt input before launch.
- Embedded terminal tabs for running reviewer agents (AppKit PTY wrapper).
- Multiple concurrent reviewer agents with nicknames and independent tabs.

### M6 — Remote / SaaS Mode

- `RemoteBackend` implementation (HTTPS/WSS to coordinator).
- Coordinator service with project configs, sandbox provisioning, session
  relay, and push notifications.
- Desktop app seamlessly switches between local and remote sessions.
- Mobile access (form factor TBD).

## 14. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| IPC complexity vs Tauri's built-in bridge | Keep protocol minimal (JSON over Unix socket); add integration tests early. |
| Swift ↔ Rust FFI surface | Use IPC (not direct FFI) for v1 to keep the boundary simple and debuggable. Evaluate `swift-bridge` or C FFI later if latency matters. |
| Diff rendering performance for large repos | Stream hunks lazily; render visible viewport first. |
| Line mapping drift after edits | Same mitigation as Tauri: store old/new anchors, best-effort remap. |
| Remote/SaaS complexity (future) | Deferred — the `ReviewBackend` trait is the insurance policy. Build local-first, validate the trait surface, then add `RemoteBackend`. |

## 15. Open Questions

- Should the IPC server be a long-running daemon, or spawn-per-session?
- Evaluate `swift-bridge` vs pure IPC for the Swift ↔ Rust boundary.
- Is SQLite WAL sufficient for concurrent CLI + app access, or do we need the
  IPC server to serialize all writes?
- Terminal emulator strategy for reviewer-agent tabs: bundle a Swift terminal
  library (e.g. SwiftTerm) or shell out to an external terminal?
- Remote/SaaS details (coordinator hosting, sandbox runtime, mobile form
  factor, secrets management) are deferred to M6 planning.
