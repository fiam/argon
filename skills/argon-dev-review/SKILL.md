---
name: argon-dev-review
description: Rebuild and launch a local development Argon review session. Use when working on the argon-native repo to test UI changes — rebuilds the Rust CLI and macOS app, kills any running instance, and opens a fresh session.
---

# Argon Dev Review

Use this skill when you need to rebuild and launch Argon from the local
checkout to test changes to the CLI or macOS app.

## When to use

- After making changes to the SwiftUI app (apps/macos/)
- After making changes to the Rust CLI or core (crates/)
- When the reviewer asks to see the current state of the app
- When you need to verify a UI fix

## Command

```bash
./scripts/dev-argon.sh [target-repo-path]
```

If no target repo is given, it reviews the current directory.

The script:
1. Builds the `argon` CLI in release mode
2. Regenerates the Xcode project via `xcodegen`
3. Builds `Argon.app` via `xcodebuild`
4. Kills any running Argon instance
5. Creates a new uncommitted-mode review session for the target repo
6. Launches the freshly built app with that session

## Examples

Review the argon-native repo itself (most common during development):

```bash
./scripts/dev-argon.sh .
```

Review a different repo:

```bash
./scripts/dev-argon.sh ~/Source/other-project
```

## After launching

The script prints the session details including the session ID. You can
use the dev commands to simulate reviewer activity:

```bash
# Add a reviewer comment
./target/release/argon agent dev comment --session <id> --message "looks good"

# Submit a decision
./target/release/argon agent dev decide --session <id> --outcome approved
```

## Troubleshooting

- If xcodegen fails, install it: `brew install xcodegen`
- If the app doesn't appear, check that `Argon.app` exists in DerivedData
- If the app shows "No session", verify the session ID was passed correctly
