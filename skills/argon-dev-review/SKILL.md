---
name: argon-dev-review
description: Build and launch a local Argon review session from the development checkout. Use from any project to trigger a human review — rebuilds the CLI and macOS app, kills any running instance, and opens the review UI. The agent then enters the review loop, waiting for feedback.
---

# Argon Dev Review

Use this skill to launch a human review of your current work using the
local Argon development build.

## Preconditions

- You are working in a Git repository.
- The Argon source is at `~/Source/argon-native` (or set `ARGON_SRC`).
- Xcode command line tools and `xcodegen` are installed.

## Workflow

### 1. Build and launch

Run the dev script from the Argon source checkout, pointing it at the
current repo:

```bash
ARGON_SRC="${ARGON_SRC:-$HOME/Source/argon-native}"
bash "$ARGON_SRC/scripts/dev-argon.sh" "$(pwd)"
```

This will:
1. Build the `argon` CLI in release mode
2. Build `Argon.app` via xcodegen + xcodebuild
3. Kill any running Argon instance
4. Create an uncommitted-mode review session for the current repo
5. Launch the app with the session

Save the session ID from the output.

### 2. Enter the review loop

After launching, use the printed commands to enter the agent review loop:

```bash
ARGON_CLI="$ARGON_SRC/target/release/argon"

# Wait for reviewer feedback (blocks until reviewer acts)
"$ARGON_CLI" --repo "$(pwd)" agent wait --session <session-id> --json
```

### 3. Handle feedback

When the wait command returns:

- If status is `approved`: commit your changes and stop.
- If status is `closed`: stop immediately, do not commit.
- If there are open threads: acknowledge each, implement fixes, reply, then wait again.

```bash
# Acknowledge
"$ARGON_CLI" --repo "$(pwd)" agent ack --session <session-id> --thread <thread-id> --json

# Reply after fixing
"$ARGON_CLI" --repo "$(pwd)" agent reply --session <session-id> --thread <thread-id> --message "<what changed>" --addressed

# Wait again
"$ARGON_CLI" --repo "$(pwd)" agent wait --session <session-id> --json
```

### 4. Keep looping

Keep waiting for reviewer feedback until the session is approved or
closed. Do not stop early. On approval, commit your changes. On close,
stop without committing.

## Quick one-liner

```bash
ARGON_SRC="${ARGON_SRC:-$HOME/Source/argon-native}" && bash "$ARGON_SRC/scripts/dev-argon.sh" "$(pwd)"
```

## Failure Handling

- If `xcodegen` is missing: `brew install xcodegen`
- If the build fails: check `$ARGON_SRC` points to the argon-native checkout
- If the session is `closed`: stop immediately
