# Argon - PRD

## 1. Product Reframe

Argon is no longer primarily a review app.

Argon is a native macOS workspace for managing Git worktrees, launching
coding agents, writing code in embedded terminals, inspecting diffs, and
handing work into review when the human wants it.

Review remains a core feature, but it becomes one component inside a
workspace-first product:

- `argon <dir>` opens the main workspace UI for a single repository.
- `argon review <dir>` opens the standalone review window.
- the CLI is also the convenient human launcher for opening and focusing
  app windows from the terminal
- `argon agent ...` remains the machine-readable review loop for agents,
  while prompt-driven handoff stays a first-class option and skills remain
  optional convenience wrappers

The new daily-driver experience is:

1. Open a repo workspace.
2. Create or select a worktree.
3. Work in agent or bare terminal tabs.
4. Inspect diff and status from the right-side inspector.
5. Launch review when ready.
6. Merge back or fix conflicts through the active coder agent.

## 2. Problem Statement

Coding agents can write code quickly, but the human still has to do the
coordination work:

- create and track worktrees
- keep multiple agents isolated
- monitor progress and diff quality
- decide when something is ready for review
- handle branch conflicts as the base branch moves
- turn branch work into a merge or pull request

Today these actions are spread across multiple terminals, ad hoc Git
commands, and separate review flows. Argon should unify them into one
native workspace.

## 3. Vision

Argon is the human control plane for local agent-driven development.

One window maps to one repository. Inside that window the user can:

- see every active worktree
- launch one or more agent terminals per worktree
- open bare shell tabs for manual commands
- inspect the selected worktree's diff at a glance
- start a formal review without leaving the workspace
- ask the active coder agent to merge back or resolve conflicts
- detect GitHub context and move naturally toward a PR when needed

The review UI stays high quality and GitHub-like, but it is not the home
screen anymore. The workspace window is.

## 4. Goals

- Make `argon <dir>` the primary human entry point.
- Make the CLI the fastest way for a user to launch and focus the app
  from the terminal.
- Keep one workspace window per repository and one review window per
  review session.
- Let humans manage multiple worktrees without manual `git worktree`
  bookkeeping.
- Make terminals first-class so coding work can happen inside Argon, not
  beside it.
- Make agent activity visible so humans can tell which agents are thinking,
  idle, blocked, or done without opening every terminal.
- Keep review explicit, native, and machine-readable.
- Detect merge conflicts continuously as the base branch changes.
- Route merge-back and conflict-fix actions through the active coder
  agent instead of hiding Git operations behind silent automation.
- Surface GitHub and PR actions when the repository supports them.

## 5. Non-Goals

- Replacing Git with a fully abstracted proprietary workflow.
- Hiding all Git concepts from the user.
- Multi-repo workspaces in a single window.
- Cloud-hosted agent orchestration or remote sessions in this phase.
- Full GitHub sync parity in the first PR integration milestone.
- Rewriting the existing review UI before the workspace shell is in place.

## 6. Primary Users

- Human developer
  Uses Argon as the main desktop app for launching worktrees, watching
  agents, reviewing diffs, resolving conflicts, and merging work back.
- Coding agent
  Runs inside a worktree terminal, writes code, summarizes changes for
  review, resolves conflicts, and performs merge-back work when asked.
- Reviewer agent
  Participates only in the review loop. Can comment and request changes,
  but cannot approve or merge.

## 7. Product Principles

- Workspace first: the default experience is managing live work, not just
  reading a diff.
- Review is explicit: approvals, requested changes, and closed sessions
  remain formal review states.
- One repository per window: avoid cross-project ambiguity.
- Agent-visible actions: merge back, conflict fixing, and review summary
  generation should be driven through a visible agent action path.
- Deterministic state: worktree status, review status, and conflict status
  should be explicit and inspectable.
- Human-visible agent state: Argon should expose whether agents are
  thinking, waiting, idle, or finished at the tab and workspace levels.
- Machine-readable first: CLI and internal contracts should stay stable
  for agent workflows.
- Human-convenient launch: the same CLI should be ergonomic for users who
  want to open the right window from the terminal without extra flags.
- Prompt-driven interoperability: agent workflows should be expressible
  through copied prompts and CLI commands, not only through installed skills.

## 8. Command Model

### 8.1 Primary Commands

```bash
argon <dir>
argon review <dir>
```

- `argon <dir>`
  Opens the workspace window for the repository containing `<dir>`.
  If `<dir>` is already a worktree inside an existing repo, Argon resolves
  the shared repository and focuses that worktree in the workspace.
- `argon review <dir>`
  Opens the standalone review window for the repository containing `<dir>`,
  equivalent to today's direct review launch.

### 8.2 Backward Compatibility

The following flows stay supported during the transition:

- `argon review --repo <dir> ...`
- `argon agent start --repo <dir> ...`
- existing agent/reviewer/draft/diff commands

The CLI should treat positional directory arguments as the preferred human
syntax while preserving machine-readable flags for agents and scripts.

### 8.3 Human Launcher Expectations

The CLI is not only an agent contract. It is also the user's convenient
launcher for the native app.

Human-launch expectations:

- short positional commands should be preferred for app launch
- opening a directory that already has a workspace window should focus it
- opening a directory inside an existing worktree should focus the correct
  repository window and selected worktree
- review launch should be equally convenient from the terminal

### 8.4 Agent Interaction Expectations

Argon should support agent interaction in three forms:

- direct prompt-driven handoff from the UI
- explicit CLI commands copied into an agent session
- optional installed skills that wrap the same underlying commands

No core review or workspace workflow should require a skill installation if
the same interaction can be expressed with prompt text and CLI commands.

## 9. UX Overview

### 9.1 Workspace Window

Each workspace window handles one repository.

Layout:

- Left pane
  Worktree list for the repository.
- Center pane
  Terminal area with tabs for the selected worktree.
- Right pane
  Diff summary, full `--stat`, review controls, merge/conflict controls,
  and PR actions.

### 9.2 Review Window

The existing review UI remains a separate window.

It opens from:

- `argon review <dir>`
- the workspace "Review" action
- `argon agent start ...`

The review window continues to own:

- diff browsing
- inline comments
- thread replies
- draft review batching
- human approval and close decisions
- reviewer-agent collaboration

### 9.3 Window Rules

- One workspace window per repository root / Git common directory.
- One review window per review session.
- Opening the same workspace twice should focus the existing window.
- Multiple review windows may exist if the user launches multiple sessions.

## 10. Requirements

### 10.1 Functional Requirements

#### FR-1 Workspace Entry Point

- `argon <dir>` must open the workspace UI.
- The app must resolve `<dir>` to the repository root or Git common
  directory before constructing the window state.
- If the directory is not inside a Git repository, Argon should fail with
  a clear message instead of opening an empty shell.

#### FR-2 Review Entry Point

- `argon review <dir>` must open the current review experience.
- This path must stay compatible with the existing agent review loop.

#### FR-3 Worktree Sidebar

The left pane must list all worktrees for the repository, including:

- display name or branch name
- filesystem path
- selected state
- active agent count
- overall agent status
- diff status summary
- review status summary
- conflict indicator
- merge readiness indicator

The sidebar should make it obvious which worktree is:

- the base branch worktree
- currently selected
- conflicted
- awaiting review
- ready to merge

#### FR-4 Terminal Tabs

The center pane must support multiple tabs per selected worktree.

Tab types:

- agent tab
  A terminal launched by Argon with an associated agent command and an
  optional control channel.
- shell tab
  A bare interactive terminal that lets the human type commands directly.

Requirements:

- users can create a new agent tab
- users can create a new shell tab
- tabs stay associated with one worktree
- tab titles should expose worktree + terminal identity
- agent tabs should surface current agent activity, including when the
  agent appears to be thinking
- closed tabs should not destroy worktree state

#### FR-5 Agent Activity Awareness

Argon should infer and display the current activity state of each agent
terminal.

At minimum, Argon should distinguish:

- unknown
- idle
- thinking
- running a command
- waiting for human input
- finished
- failed

Detection should use the most reliable available signal for each agent:

- structured control-channel events when available
- terminal title or status text emitted by supported agents
- process lifecycle and exit status
- conservative terminal-output heuristics as a fallback

Many agents write transient status text near the top of the terminal or tab
area while they are thinking. Argon should use Ghostty integration points to
observe that status where possible, but the UI must treat heuristic detection
as best-effort and allow an unknown state.

The tab strip must show agent activity directly on each agent tab, with a
clear visual treatment for thinking agents.

The worktree sidebar row must aggregate agent activity for that worktree so
the user can scan the workspace list and see whether any agent is thinking,
blocked, failed, or done without selecting the worktree.

Argon should include a setting:

- `Prevent sleep while agents are thinking`

The setting should default to enabled. When enabled, Argon should prevent
system sleep while any agent tab is in the thinking state. The prevention
must end promptly when no agent is thinking, the relevant workspace closes,
or Argon exits. The UI should make this behavior discoverable without
interrupting normal agent work.

#### FR-6 Diff Inspector

The right pane must show diff information for the selected worktree
relative to its configured base branch.

It must include:

- total added / removed counts
- file count
- full `git diff --stat` style summary
- review session status if a review exists
- last updated timestamp or refresh state

#### FR-7 Review Action

The right pane must expose a "Review" action that opens the existing
review UI for the selected worktree.

Before opening the review window, Argon must try to obtain a coder-agent
summary of the changes to use as the review description / PR description.

If there is:

- one eligible coder agent
  use it automatically
- multiple eligible coder agents
  ask the user to choose one
- no eligible coder agent
  prompt the user to launch one or continue with a manual summary

The captured summary must be:

- stored on the worktree
- editable by the human before review submission
- passed to reviewer agents as context

#### FR-8 Merge Back Action

The right pane must expose a "Merge Back" action for the selected
worktree.

Behavior:

- the action targets the repository's configured base branch
- Argon must not silently perform the merge in the background in phase 1
- instead, Argon must send the task to an eligible coder agent attached
  to that worktree

Agent selection rules:

- one eligible coder agent: use it automatically
- multiple eligible coder agents: ask the user to choose
- no eligible coder agents: prompt the user to launch one

On successful merge-back, Argon should offer or automatically perform:

- worktree close
- worktree cleanup
- terminal tab closure for that worktree

based on repository configuration.

#### FR-9 Continuous Conflict Detection

Argon must continuously detect whether each open worktree conflicts with
the latest base branch.

Triggers:

- base branch HEAD changes
- worktree HEAD changes
- worktree index / working tree changes when relevant
- successful merge-back of another worktree

Conflict state must update in the workspace UI without requiring the user
to reopen the window.

#### FR-10 Fix Conflicts Action

When a worktree is marked conflicted, the right pane must expose a
"Fix Conflicts" action.

This action uses the same agent-selection rules as merge-back:

- one eligible coder agent: use it automatically
- multiple eligible coder agents: ask the user to choose
- no eligible coder agents: prompt the user to launch one

#### FR-11 GitHub Detection and PR Action

Argon must automatically detect when the repository is connected to
GitHub.

At minimum, the right pane must show a PR action when the selected
worktree belongs to a GitHub-backed repository.

Phase 1 behavior may be:

- open the branch or compare URL in GitHub
- open an existing PR if one is already known
- open the new-PR flow in the browser

Later milestones may add direct PR creation and status sync.

#### FR-12 Explicit State Model

Review state must remain explicit:

- `awaiting_reviewer`
- `awaiting_agent`
- `approved`
- `closed`

Workspace state must not overload review state.

Each worktree should track at least:

- worktree lifecycle state
- review state
- conflict state
- terminal / agent activity state
- merge readiness state

#### FR-13 Review Handoff Context

When a review is launched from the workspace, reviewer agents must receive
the coder summary as first-class context, not just the raw diff.

The summary should resemble a PR description and include:

- summary of change intent
- important implementation details
- testing performed
- known risks or follow-ups

#### FR-14 Prompt-Driven Agent Interop

Agent workflows must be usable without requiring a skill installation.

Requirements:

- the UI should be able to hand the human a prompt bundle or command text
  for coder and reviewer agents
- agents must be able to participate through copied prompts plus CLI
  commands only
- skills may accelerate the workflow, but they must not be the only
  supported path

#### FR-15 Post-Commit Review Reset

Argon must not continue showing an old review decision as if it applied to
new changes after the coder agent commits or otherwise materially changes
the reviewed target.

Requirements:

- after commit, the coder agent should explicitly notify completion back to
  Argon or through the human-visible handoff flow
- that notification must let Argon clear, close, or retarget the old review
  state
- the UI must refresh so fresh post-commit changes appear unreviewed unless
  a new review session has been created for them

#### FR-16 Persistence

Argon must persist enough workspace state to restore:

- open worktrees
- selected worktree
- open terminal tabs metadata
- review summaries
- known PR metadata
- conflict status cache

Terminal scrollback persistence is optional in the first milestone.

#### FR-17 Configuration

The repository-level config must support:

- base branch selection
- merge-back cleanup policy
- default agent selection
- prevent sleep while agents are thinking, default enabled
- GitHub remote preference if multiple remotes exist

### 10.2 Non-Functional Requirements

#### NFR-1 Performance

- workspace window cold open target: under 1 second for common repos
- worktree list refresh should feel immediate
- diff summary refresh should not block terminal interaction

#### NFR-2 Reliability

- background conflict checks must tolerate transient Git failures
- app relaunch should not orphan persisted worktree metadata
- review sessions must remain valid even if the workspace window closes

#### NFR-3 Determinism

- worktree detection and branch mapping should be reproducible
- conflict status should be derived from explicit Git checks, not heuristics
- action availability should be based on explicit state, not inferred UI timing
- heuristic agent activity detection must expose confidence and fall back to
  `unknown` instead of presenting uncertain state as fact

#### NFR-4 Machine-Readable Contracts

- all agent-facing CLI outputs must remain JSON-capable
- any new action contract used to talk to coder agents should have a
  structured representation even if the first UI transport is terminal-based

## 11. SPEC

### 11.1 Domain Model

#### RepositoryWorkspace

- `repo_root`
- `git_common_dir`
- `base_branch`
- `worktrees`
- `github_repo`
- `selected_worktree_id`
- `last_scan_at`

#### WorkspaceWorktree

- `id`
- `branch`
- `path`
- `is_base_worktree`
- `head_sha`
- `dirty_state`
- `review_session_id`
- `review_state`
- `conflict_state`
- `merge_state`
- `aggregate_activity_state`
- `agent_tabs`
- `latest_summary`
- `pull_request`

#### TerminalTab

- `id`
- `worktree_id`
- `kind` = `agent` | `shell`
- `title`
- `cwd`
- `launch_command`
- `agent_capabilities`
- `status`
- `activity_state`
- `activity_confidence`
- `last_activity_signal_at`

#### PullRequestReference

- `provider`
- `remote_name`
- `owner`
- `repo`
- `number`
- `url`
- `head_branch`
- `base_branch`

### 11.2 State Separation

Argon should model worktree state across separate axes instead of one
flattened enum.

Recommended axes:

- `worktree_state`
  `active` | `closing` | `closed`
- `review_state`
  `none` | `awaiting_reviewer` | `awaiting_agent` | `approved` | `closed`
- `conflict_state`
  `unknown` | `clean` | `conflicted`
- `merge_state`
  `idle` | `ready` | `merging` | `merged` | `failed`
- `activity_state`
  `unknown` | `idle` | `thinking` | `running_command` | `waiting_for_human`
  | `finished` | `failed` | `running_shell_only`

This prevents review lifecycle from being confused with Git mergeability or
terminal activity.

### 11.3 Workspace Layout Spec

#### Left Pane

- worktree rows with branch, short path, and badges
- inline status badges for review / conflict / PR presence
- aggregate agent activity badges, including a visible thinking state
- sorting by base worktree first, then active worktrees, then recency
- action affordance to create a new worktree

#### Center Pane

- tab strip scoped to the selected worktree
- new agent tab button
- new shell tab button
- per-tab agent activity indicator
- terminal view embedded with Ghostty
- optional empty state when no tabs exist for the selected worktree

#### Right Pane

- diff summary header
- added / removed / file counts
- full `git diff --stat` block
- latest coder summary preview
- `Review` button
- `Merge Back` button
- `Fix Conflicts` button when needed
- `PR` button when GitHub is detected

### 11.4 CLI Routing Spec

#### Workspace Launch

```bash
argon <dir>
```

Behavior:

1. resolve repository root / common dir
2. open or focus workspace window
3. select the worktree matching `<dir>` if applicable

#### Review Launch

```bash
argon review <dir>
```

Behavior:

1. resolve repository root / review target
2. create or reuse a review session
3. open review window

Compatibility:

- keep `argon review --repo <dir>` working
- keep `argon agent start --repo <dir>` unchanged for skills

### 11.5 Agent Control Spec

Argon needs a shared abstraction for "ask the coder agent to do a thing"
that can power:

- review-summary generation
- merge back
- fix conflicts

Proposed abstraction:

- `AgentControlTarget`
  identifies an eligible agent tab for a worktree
- `AgentControlRequest`
  typed request with goal, repo path, worktree path, and structured context
- `AgentControlResult`
  success, failure, timeout, or declined

Phase 1 transport can still be terminal-backed, but the request and result
shapes should be explicit in Rust domain types.

The transport must support both:

- prompt-driven agent handoff
- optional skill-backed wrappers over the same request model

### 11.6 Review Summary Spec

When the user launches review from the workspace, Argon should request a
structured summary from the chosen coder agent.

Required fields:

- title
- summary
- testing
- risks

Storage rules:

- save it on the worktree record
- prefill the review description UI
- include it in reviewer-agent prompts

Fallback rules:

- if the agent request fails or times out, let the human author the summary
- do not block the review window forever on summary generation

### 11.7 Merge-Back Spec

Merge-back targets the configured base branch, defaulting to `main`.

Flow:

1. user clicks `Merge Back`
2. Argon resolves the eligible coder agent
3. Argon sends merge instructions with repository context
4. agent performs the merge work in the selected worktree
5. Argon refreshes Git state
6. if merged successfully, Argon offers cleanup / close
7. conflict state for other worktrees is recomputed immediately

If the merge-back or approved work ends in a commit, the coder agent should
report completion so Argon can reset or retarget the review state instead of
showing the previous `approved` decision for fresh changes.

### 11.8 Conflict Detection Spec

Conflict detection should compare each non-base worktree against the
current base branch tip.

Minimum contract:

- use explicit Git operations that can answer "would this branch conflict
  if merged now?"
- rerun after base branch movement and after worktree changes
- cache latest result and timestamp per worktree

UI contract:

- conflicted worktrees show a badge in the sidebar
- selected conflicted worktrees show `Fix Conflicts`
- merge-back should be disabled or guarded when conflict state is red

### 11.9 GitHub / PR Spec

GitHub detection should inspect configured remotes and identify whether the
repository maps to a GitHub-hosted project.

Phase 1 requirements:

- detect provider + owner/repo from Git remotes
- show a `PR` button in the workspace inspector
- if a PR already exists for the branch, open it
- otherwise open the compare / new-PR URL

Future extension:

- direct PR creation from Argon
- PR status and review status sync

## 12. Architecture Impact

### 12.1 Rust Core

`argon-core` needs new workspace-first services:

- worktree discovery and refresh
- workspace persistence
- conflict monitor
- GitHub remote parsing
- agent control request types
- diff summary / stat generation for worktree inspector

The existing review types remain, but they should become one subsystem of a
larger workspace domain.

### 12.2 Backend Boundary

The current `ReviewBackend` abstraction should remain for review windows.

The workspace likely needs a separate backend or service layer rather than
forcing review-only abstractions to own:

- worktrees
- terminals
- conflicts
- merge state
- GitHub metadata

### 12.3 CLI

The CLI must be updated to:

- route `argon <dir>` to workspace launch
- accept `argon review <dir>`
- preserve review-loop commands unchanged
- add workspace-oriented machine-readable commands later if needed

Future v2 direction:

- host an in-app MCP server so embedded agents can call Argon tools
  directly instead of relying only on copied prompts or shell commands
- expose narrow workspace actions first, especially worktree creation and
  reviewer-agent requests
- add centrally managed connector support so agents can be connected to
  shared services from one place, with MCP as the primary surface and
  optional skills as wrappers
- keep saved agent profiles as the authority for which reviewer agents can
  be launched through that MCP surface

### 12.4 macOS App

The macOS app should be split into:

- workspace shell
- review window
- shared terminal components
- shared Git / diff inspector models

The current review UI should be reused instead of rewritten.

## 13. Implementation Plan

### Phase 0 - Rebaseline Around Workspace

- update PRD and product messaging
- keep review flow intact while redefining the top-level app model
- decide repository identity model: repo root vs Git common dir

Exit criteria:

- product docs consistently describe workspace-first behavior
- CLI transition plan is explicit

### Phase 1 - CLI Split and Window Routing

- make `argon <dir>` open the workspace window
- make `argon review <dir>` open the review window
- preserve `argon agent start ...` and current review contract, whether the
  agent is following a copied prompt or an installed skill
- add compatibility coverage for old flag-based review entry

Exit criteria:

- humans have a clear workspace entry point
- current review workflows still function unchanged

### Phase 2 - Workspace Shell and Worktree Catalog

- build the new workspace window chrome
- add left worktree sidebar
- scan and persist repository worktrees
- select and focus worktrees cleanly

Exit criteria:

- one repository window can display and switch between worktrees

### Phase 3 - Terminal Tabs

- add center-pane tab model
- support bare shell tabs
- support agent tabs
- bind tabs to selected worktree
- detect and display agent activity state in each agent tab
- add the default-enabled sleep prevention setting for thinking agents
- aggregate agent activity state into each worktree row

Exit criteria:

- user can do actual coding work inside Argon and can see which agents are
  actively thinking without opening each terminal

### Phase 4 - Diff Inspector and Review Handoff

- add right-side diff summary
- add full `git diff --stat`
- add `Review` action from workspace
- request coder summary before review launch
- feed the summary into review sessions and reviewer prompts

Exit criteria:

- review launch feels like a transition from active work into formal review

### Phase 5 - Merge Back Orchestration

- add `Merge Back` action
- implement agent selection flow
- add cleanup / close behavior after success

Exit criteria:

- user can merge a worktree back from the workspace through the coder agent

### Phase 6 - Conflict Detection and Resolution

- run continuous mergeability checks
- surface conflicts in the sidebar and inspector
- add `Fix Conflicts` action using the same agent-selection flow

Exit criteria:

- workspace reacts when the base branch changes underneath open worktrees

### Phase 7 - GitHub and PR Actions

- detect GitHub remotes
- surface PR button
- open existing PR or new-PR flow
- persist branch-to-PR references when known

Exit criteria:

- GitHub-backed repos have a natural path from local branch work to PR

### Phase 8 - Polish and Stabilization

- restore workspace state on relaunch
- tighten notifications
- test larger repos and multiple concurrent worktrees
- update packaging and onboarding docs

Exit criteria:

- workspace mode is stable enough to replace the current review-first entry

### Phase 9 - MCP Workspace Actions

- add an in-app MCP server hosted by the macOS app
- expose worktree creation / listing tools to embedded agents
- expose reviewer-agent request tools so one agent can ask another saved
  agent profile for review
- add connector management so shared service integrations can be configured
  once and exposed consistently to embedded agents
- keep approval / visibility boundaries explicit for privileged actions

Exit criteria:

- embedded agents can create worktrees and request reviewer agents through
  typed Argon tools instead of prompt conventions alone

## 14. Milestones

| Milestone | Scope | Outcome |
|---|---|---|
| M0 | Existing foundation | Review engine, review UI, live diff refresh, and agent review loop remain intact. |
| M1 | CLI routing | `argon <dir>` opens workspace, `argon review <dir>` opens review, compatibility preserved. |
| M2 | Workspace shell | Left / center / right layout ships with repository-scoped window model. |
| M3 | Worktree management | Worktree discovery, selection, status badges, and persistence land. |
| M4 | Terminal tabs | Agent tabs and shell tabs work in the center pane, with visible agent activity and sleep prevention. |
| M5 | Diff inspector | Right pane shows diff summary, full `--stat`, and review entry point. |
| M6 | Review handoff | Coder summary is requested and injected into review / reviewer context. |
| M7 | Merge-back flow | Merge-back action delegates to coder agent and supports close / cleanup. |
| M8 | Conflict handling | Continuous conflict detection and `Fix Conflicts` action ship. |
| M9 | GitHub / PR flow | GitHub detection and PR button ship for supported repos. |
| M10 | Stabilization | Persistence, UX polish, and reliability hardening complete the transition. |
| M11 | MCP workspace actions | Embedded agents can create worktrees, request reviewer agents, and use centrally managed service connectors through an in-app MCP server. |

## 15. Testing and Validation Requirements

- Add extensive UI and unit test coverage for the new workspace-first
  flows, including worktree selection, terminal tab management, review
  launch, merge-back, conflict handling, PR actions, and post-commit UI
  reset.
- Add Rust tests for worktree discovery, conflict detection, GitHub remote
  parsing, and any new CLI routing behavior.
- Add Swift tests for workspace state restoration, worktree selection, and
  inspector action availability.
- Keep existing review-session tests passing unchanged.
- Add end-to-end coverage for:
  - launching workspace from a directory
  - opening review from workspace
  - agent-selection prompts for merge-back and conflict fix
  - conflict status updates after base branch movement
- Validate performance on repositories with multiple open worktrees and
  moderately large diffs.

## 16. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Workspace scope sprawls beyond review foundation | Keep review UI reusable and layer workspace features around it incrementally. |
| Terminal complexity blocks core product work | Start with tab and process model first; keep terminal renderer work isolated. |
| Merge-back through agents feels unreliable | Define explicit agent control request/result types and visible status. |
| Conflict detection becomes noisy or slow | Trigger checks from explicit Git events and cache results per worktree. |
| GitHub integration creates premature API surface | Start with remote detection and browser deep links before full API sync. |

## 17. Open Questions

- Should the repository identity key be the repo root path or the Git common
  directory path when opening workspace windows?
- Should the base worktree itself appear in the left pane as a selectable row,
  or stay implicit as the target branch context only?
- What is the first structured transport for coder-agent control requests:
  terminal prompt injection, a sidecar CLI contract, or both?
- Should merge-back default to a merge commit, rebase + fast-forward, or
  another policy controlled by config?
- Should PR detection support GitHub Enterprise in phase 1 or only
  `github.com` remotes?
