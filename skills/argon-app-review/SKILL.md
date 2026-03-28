---
name: argon-app-review
description: Run a human-in-the-loop local review cycle through the argon CLI and native app. Use when an agent needs to pause for reviewer feedback, collect line/global comments, handle requested changes, post comment replies, and wait for final approval.
---

# Argon App Review

Use this skill to coordinate agent work with a human reviewer through the
Argon native review app.

## Preconditions

- Run inside a Git repository.
- Ensure the `argon` CLI is available (bundled in `Argon.app/Contents/Resources/bin/argon` or on PATH).

## Resolve the CLI

- Prefer a full handoff command from the Argon UI if one was provided.
- Otherwise resolve the bundled CLI with:

```bash
"$SKILL_DIR/scripts/find-argon-cli.sh"
```

- The resolver checks, in order:
  - `ARGON_CLI`
  - `ARGON_APP`
  - `/Applications/Argon.app`
  - `$HOME/Applications/Argon.app`

If the reviewer installed the app somewhere else, set `ARGON_APP` to the
absolute `.app` path or `ARGON_CLI` to the absolute bundled CLI path.

## Workflow

### 1. Start a session and open the review UI

```bash
argon agent start --repo <directory> --mode <branch|commit|uncommitted> \
  [--base <branch>] [--head <branch>] [--commit <sha>] \
  --description "<planned changes>" --wait --json
```

You **must** provide:
- `--repo <directory>` — the working directory to review.
- `--mode` — one of:
  - `branch` — diff from merge-base of `--base` to working tree.
  - `commit` — diff from `--commit` (default `HEAD`) to working tree.
  - `uncommitted` — `HEAD` to working tree (staged + unstaged only).
- `--description` — a short summary of the intended changes for the reviewer.

`--wait` blocks until the reviewer submits feedback or a decision.

### 2. Handle feedback — acknowledge, implement, reply

```bash
# Acknowledge a thread before starting work on it
argon agent ack --session <session-id> --thread <thread-id> --json

# After implementing the fix, reply with what changed
argon agent reply --session <session-id> --thread <thread-id> \
  --message "<what you changed>" --addressed
```

Acknowledge each open thread, implement the requested change, then reply
with a concrete description of what you did. The `--addressed` flag marks
the thread as handled.

### 3. Await re-review

```bash
argon agent wait --session <session-id> --json
```

Blocks until the reviewer responds again. Returns the same JSON structure
as `start --wait`.

**Keep looping steps 2-3 until the session reaches a terminal state.**

### 4. Terminal states

- **`approved`**: the reviewer has approved. Create a commit (or whatever
  finalization the reviewer requested) and then stop.
- **`closed`**: the reviewer closed the window or cancelled the session.
  Stop immediately — no commit, no further changes.
- Any other state (`changes_requested`, `commented`, `awaiting_reviewer`):
  keep looping. Never give up or stop polling while the session is active.

**Keep waiting for reviewer feedback until the session is approved or
closed. Do not stop early. On approval, commit your changes. On close,
stop without committing.**

### 5. Check status without blocking

```bash
argon agent status --session <session-id> --json
```

### 6. Close a session explicitly (if needed)

```bash
argon agent close --session <session-id> --json
```

## Output Handling

Treat review outputs as authoritative.

- `approved`: finalize and summarize.
- `closed`: stop immediately; the reviewer closed the UI or ended the session.
- `changes_requested`: address each thread before asking for re-review.
- `commented`: treat as non-blocking guidance unless message indicates otherwise.

## Agent Behavior Rules

- Reply on each requested-change thread with concrete actions taken.
- Acknowledge each open thread before starting implementation work on it.
- Use `argon agent wait --session <id> --json` as the primary blocking loop.
- If the session becomes `closed`, stop instead of continuing to wait.
- Reviewer-agent feedback is advisory. Do not stop just because another agent
  says the work looks good; only the human reviewer can give the final approval.
- Keep replies specific, include file paths and rationale.
- Do not claim a fix is complete until code and tests (if applicable) are updated.
- Re-enter `argon agent wait --session <id> --json` after handling feedback.

## Failure Handling

- If the bundled CLI cannot be found, report that `Argon.app` is missing and
  tell the user to set `ARGON_APP` or `ARGON_CLI`.
- If a session or thread lookup fails, run `status --json` first and verify the
  repo root and session id.
- If `agent wait --json` returns `closed`, stop immediately and report that the
  reviewer ended the session from the UI.
