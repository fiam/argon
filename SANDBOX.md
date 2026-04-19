# Sandbox

Argon can launch shells and agents inside a local sandbox.

Today that means:

- the policy language is `Sandboxfile`
- the shared implementation lives in `crates/sandbox`
- enforcement exists on macOS only
- network policy is not implemented yet

The low-level entrypoint is `argon sandbox exec`.

## Configuration Files

Argon resolves policy by walking parent directories upward from the launch
directory.

In each directory on that walk, Argon recognizes:

- `Sandboxfile`
- `.Sandboxfile`
- `.Sanboxfile`

At most one sandbox file may exist per directory. If more than one of those
files exists in the same directory, Argon errors instead of guessing.

Inspect the resolved paths with:

```bash
argon --repo <repo> sandbox config paths
argon --repo <repo> sandbox config paths --json
```

## Initialization

Create a default repo `Sandboxfile` with:

```bash
argon sandbox init --repo-root <repo>
argon sandbox init --repo-root <repo> --json
```

`argon sandbox exec` also creates a default repo `Sandboxfile` automatically
when sandboxing is requested and the repo has none yet.

In the macOS app, sandboxed shell, agent, and reviewer launches show a
confirmation dialog when no `Sandboxfile` is discovered. That dialog
explains what the default scaffold does, creates it on confirmation, and
reminds the user that it can be customized later by editing `Sandboxfile`.
The app Settings window also includes a dedicated Sandbox tab that explains
the layering model, including `$HOME/.Sandboxfile` as a user-level policy
file applied after repo-local sandbox files.

The generated scaffold is intentionally small:

```text
# This file describes the Argon Sandbox configuration
# Full docs: https://github.com/fiam/argon/blob/main/SANDBOX.md

ENV DEFAULT NONE # Start from a minimal process environment by default.
FS DEFAULT NONE # Start from no filesystem access by default.
EXEC DEFAULT ALLOW # Allow running any command by default.
FS ALLOW READ . # Allow reading files inside this repository.
FS ALLOW WRITE . # Allow edits inside this repository.
USE os # Allow access to the operating system's shared filesystem without exposing personal directories.
USE shell # Allow the current shell binary and shell history when they apply.
USE agent # Load agent-specific config and state when they apply.
IF TEST -f ./Sandboxfile.local # Check for an optional repo-local sandbox extension file.
    USE ./Sandboxfile.local
END
```

## Evaluation Model

Argon evaluates policy in this order:

1. seed variables from the launch context and current environment
2. walk parent directories upward from the launch directory
3. evaluate one discovered sandbox file per directory, from nearest to farthest
4. append explicit `--write-root` launch roots
5. resolve bare `EXEC ALLOW <command>` entries against `PATH`
6. resolve `EXEC INTERCEPT` handlers and prepare the shim runtime

`USE` expands builtins inline at the point where it appears. That makes
source order meaningful without turning the language into a general scripting
system.

`USE ./relative/path` resolves from the including file's directory, so repo
policies can opt into local extensions such as `./Sandboxfile.local`.

A common setup is:

- `Sandboxfile` in the repo for repo-local policy
- `./Sandboxfile.local` for machine-local repo extensions
- `$HOME/.Sandboxfile` for user-level policy applied after the repo-local
  sandbox files

## Language

Supported instructions today:

```text
SET NAME value
USE module
WARN "message"

IF TEST ...
ELSE
SWITCH value
CASE value
DEFAULT
END

ENV DEFAULT INHERIT
ENV DEFAULT NONE
ENV ALLOW NAME
ENV ALLOW FOO_*
ENV SET NAME value
ENV UNSET NAME

FS DEFAULT NONE
FS DEFAULT READ
FS DEFAULT READWRITE
FS ALLOW READ path
FS ALLOW WRITE path

EXEC DEFAULT ALLOW
EXEC DEFAULT DENY
EXEC ALLOW git
EXEC ALLOW ./bin
EXEC INTERCEPT aws WITH .argon/sandbox/intercepts/aws.sh
```

Notes:

- if omitted, `ENV DEFAULT`, `FS DEFAULT`, and `EXEC DEFAULT` all default to `NONE`
- `FS ALLOW READ` and `FS ALLOW WRITE` accept either files or directories
- directory-vs-file is inferred from the existing path, or forced by a trailing `/`
- directory-style paths must already exist; optional directories should be
  guarded with `IF TEST -d ...`
- read-only file paths and explicit exec file paths must already exist; optional
  files should be guarded with `IF TEST -f ...`
- writable file paths may point at files that do not exist yet, but their
  parent directory must already exist
- relative paths in the repo file resolve from the repo root
- relative paths in the user file resolve from the home file location
- relative paths in `USE ./path` resolve from the file that contains the `USE`
- explain output shows normalized absolute paths and may display resolved
  symlink targets where canonicalization succeeds
- bare `EXEC ALLOW git` searches `PATH` and allows every matching executable
- path-like `EXEC ALLOW /abs/tool` or `EXEC ALLOW ./bin/tool` allow that
  specific file or directory only
- builtins use the same language as normal repo files
- legacy `VERSION 1` lines are still accepted for compatibility, but new files
  should omit them

## Conditionals

Conditionals use `test`-style checks rather than a custom expression syntax:

```text
IF TEST "$LAUNCH" = "shell"
USE shell
END

IF TEST -n "$HISTFILE"
FS ALLOW WRITE $HISTFILE
ELSE
FS ALLOW WRITE $HOME/.zsh_history
END

IF TEST -d "$HOME/.oh-my-zsh"
FS ALLOW READ $HOME/.oh-my-zsh/
END
```

Supported operators today:

- unary: `-n`, `-z`, `-e`, `-d`, `-f`, `-L`
- binary: `=`, `!=`
- negation: leading `!`

In `IF TEST`, missing variables expand to the empty string. In policy payloads
such as `FS ALLOW WRITE $FOO`, missing variables are errors.

For exact-match dispatch, `SWITCH` is often more ergonomic:

```text
SWITCH "$OS"
CASE "macos"
USE os/macos
DEFAULT
WARN "unsupported OS: $OS"
END
```

## Variables

Argon passes the raw process environment into evaluation. That means shell and
tool variables like `HOME`, `PATH`, `SHELL`, `HISTFILE`, `ZDOTDIR`,
`XDG_CONFIG_HOME`, and `TMPDIR` are available directly as `$NAME` or
`${NAME}`.

Argon also seeds a small set of derived variables:

- `$OS`
- `$LAUNCH`
- `$INTERACTIVE`
- `$CURRENT_DIR`
- `$REPO_ROOT`
- `$SESSION_DIR`
- `$USER_CONFIG_HOME`
- `$USER_CACHE_HOME`
- `$USER_STATE_HOME`
- `$XDG_CONFIG_HOME`
- `$XDG_CACHE_HOME`
- `$XDG_STATE_HOME`
- `$XDG_DATA_HOME`
- `$TMPDIR`
- `$SHELL_NAME`
- `$AGENT`
- `$ARGC`
- `$ARGV0`, `$ARGV1`, ...
- `$ARGV0_BASENAME`

`SET` can define new variables for later rules:

```text
SET TOOL_STATE_DIR "$HOME/Library/Application Support/MyTool"
FS ALLOW WRITE $TOOL_STATE_DIR
```

## Environment Policy

If you do not set `ENV DEFAULT`, sandboxed processes start with an empty
environment. The generated default `Sandboxfile` still writes
`ENV DEFAULT NONE` explicitly for clarity.

You can replace that with explicit `ENV ALLOW` rules:

```text
ENV DEFAULT NONE
ENV ALLOW HOME
ENV ALLOW PATH
ENV ALLOW LC_*
ENV ALLOW OPENAI_*
ENV SET FOO sandboxed
ENV UNSET AWS_SESSION_TOKEN
```

Rules:

- `ENV DEFAULT INHERIT` keeps the incoming environment
- `ENV DEFAULT NONE` starts from an empty environment
- `ENV ALLOW NAME` preserves an exact variable from the incoming environment
- `ENV ALLOW FOO_*` preserves variables that match a shell-style wildcard
  pattern such as `*` or `?`
- `ENV SET` overrides the launched process environment and updates later
  `Sandboxfile` evaluation
- `ENV UNSET` removes a variable from the launched process environment and
  from later `Sandboxfile` evaluation

Inspect the effective environment policy with:

```bash
argon --repo <repo> sandbox explain --json
```

## Builtins

Builtins are authored in `Sandboxfile` syntax and compiled into Argon.

Current builtins:

- `os/macos`
- `shell/bash`
- `shell/fish`
- `shell/zsh`
- `agent/claude`
- `agent/codex`
- `agent/gemini`

Common entrypoints and includes:

- `USE os`
- `USE shell`
- `USE agent`
- `USE ./Sandboxfile.local`

These are ordinary builtin modules, not evaluator-level shorthands. They
dispatch internally to more specific modules such as `os/macos`,
`shell/zsh`, or `agent/codex` based on the current launch context. Relative
`USE` paths are file includes, not builtin lookups.

`USE shell` is intentionally minimal. It grants access to the current shell
binary and the shell's history file when those variables are available. It
does not automatically grant access to shell startup files, prompt tools, or
other personal configuration under your home directory. If a shell needs more
than that, add explicit rules in `Sandboxfile` or `Sandboxfile.local`.

`USE agent` dispatches from `$AGENT` when the launcher provides an explicit
agent family. If `$AGENT` is unset, it falls back to `$ARGV0_BASENAME` for
direct launches such as `codex` or `/opt/homebrew/bin/codex`.

Inspect builtins with:

```bash
argon sandbox builtin list
argon sandbox builtin print shell
argon sandbox builtin print shell --json
argon sandbox builtin print os/macos
```

## Intercepts

`EXEC INTERCEPT` lets Argon wrap specific command names with a handler script:

```text
EXEC INTERCEPT aws WITH .argon/sandbox/intercepts/aws.sh
```

Semantics:

- Argon resolves the real command from `PATH`
- Argon creates a temporary shim directory and prepends it to `PATH`
- the shim re-enters the Argon binary and dispatches to the handler
- the handler still runs inside the same sandbox
- the handler receives:
  - `ARGON_SANDBOX_INTERCEPTED_COMMAND`
  - `ARGON_SANDBOX_REAL_COMMAND`
- the handler sees the original `PATH`, not the shim-prefixed one

This keeps interception compatible with future policy work instead of treating
wrapped commands as an escape hatch.

`EXEC INTERCEPT` only mediates command lookup through `PATH`. If a child
process executes an absolute path directly, the intercept does not fire.

## Check

Use `argon sandbox check` to validate the discovered `Sandboxfile` stack for the
current launch context before attempting a launch:

```bash
argon --repo <repo> sandbox check
argon --repo <repo> sandbox check --launch shell --interactive
argon --repo <repo> sandbox check --json
```

`sandbox check` validates the same plan that `sandbox exec` uses:

- parsed `Sandboxfile` syntax and control flow
- builtin and relative `USE` expansion
- referenced directories and required read/exec file paths
- `EXEC ALLOW name` resolution through `PATH`
- `--write-root` arguments

If validation fails, Argon reports the originating file and line number.

## Explain

Use `argon sandbox explain` to see the resolved launch context, loaded source
files, config search order, warnings, effective filesystem and exec policy,
intercept plan, and environment shaping:

```bash
argon --repo <repo> sandbox explain
argon --repo <repo> sandbox explain --launch shell --interactive
argon --repo <repo> sandbox explain --launch agent --agent-family codex --json
```

This is the primary debugging tool for `Sandboxfile`.

The plain-text formatter merges filesystem entries by path and shows effective
access such as `[read]` or `[read, write]`.

## `argon sandbox exec`

`argon sandbox exec` resolves the effective policy, applies the sandbox to the
current process, and then runs the requested command.

Before applying the OS sandbox, `sandbox exec` performs the same validation as
`sandbox check`. Invalid paths, missing commands, or invalid `--write-root`
arguments fail early with a `Sandboxfile` location instead of a lower-level
macOS sandbox error.

Example:

```bash
argon sandbox exec \
  --repo-root /path/to/repo \
  --write-root /path/to/repo \
  --write-root /path/to/repo/.argon/sessions \
  --launch agent \
  --agent-family codex \
  --session-dir /path/to/repo/.argon/sessions/review-123 \
  --interactive \
  -- codex
```

Useful context flags:

- `--repo-root`
- `--write-root`
- `--launch command|shell|agent|reviewer`
- `--agent-family`
- `--session-dir`
- `--interactive`

## macOS Backend Notes

Argon's current macOS backend uses the `sandbox_init_with_parameters` family
from `libsandbox`.

Today the macOS implementation enforces:

- read restrictions
- write restrictions
- executable allow/deny policy
- intercept shims inside the sandbox

## Cross-Platform Structure

The policy parser and evaluator live in the shared `crates/sandbox` crate.
Platform-specific enforcement lives behind a backend boundary so Linux and
Windows implementations can be added later without changing the `Sandboxfile`
format.
