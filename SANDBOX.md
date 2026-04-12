# Sandbox

Argon can launch reviewer agents inside a filesystem sandbox.

Today that means:

- sandboxing is enforced on macOS
- the abstraction lives in `crates/sandbox`
- the low-level launcher is `argon sandbox exec`

The current macOS implementation uses the `sandbox_init_with_parameters`
family from `libsandbox`. These APIs are deprecated by Apple, but they remain
widely used for custom non-App-Store sandboxing.

## What The Sandbox Allows

Argon's reviewer sandbox is deny-by-default for file writes, then adds an
allow-list.

The effective writable set is:

1. explicit write roots passed at launch time
2. built-in default writable paths and roots
3. user sandbox config additions
4. repo sandbox config additions

For reviewer agents launched by Argon, the explicit write roots always include:

- the reviewed repo root
- the Argon session directory for that repo

That keeps agents able to edit the target directory and write session state.

## Built-In Defaults

Inspect the current machine's defaults with:

```bash
argon sandbox defaults
argon sandbox defaults --json
```

The defaults are environment-sensitive. On macOS they currently include:

- exact path: `/dev/null`
- temp roots from `std::env::temp_dir()`, `TMPDIR`, `/tmp`, `/private/tmp`,
  `/var/tmp`, and `/private/var/tmp`
- `XDG_STATE_HOME` when set
- `XDG_CACHE_HOME` when set
- under `HOME`:
  - `.claude.json`
  - `.claude.json.lock`
  - `.local/state`
  - `.cache`
  - `Library/Caches`
  - `.claude`
  - `.codex`
  - `.gemini`

This is why shell tooling that writes under cache/state directories can work
without each repo needing its own exception.

## Config Discovery

Argon supports one repo-local sandbox config and one user/global sandbox
config. Each scope may use exactly one file format. If more than one sandbox
config file exists in the same scope, Argon errors instead of guessing.

Repo-local candidates:

- `.sandbox.yaml`
- `.sandbox.yml`
- `.sandbox.toml`
- `.sandbox.json`

User/global candidates:

- `$XDG_CONFIG_HOME/argon/sandbox.yaml`
- `$XDG_CONFIG_HOME/argon/sandbox.yml`
- `$XDG_CONFIG_HOME/argon/sandbox.toml`
- `$XDG_CONFIG_HOME/argon/sandbox.json`

Fallback when `XDG_CONFIG_HOME` is unset:

- `$HOME/.config/argon/sandbox.yaml`
- `$HOME/.config/argon/sandbox.yml`
- `$HOME/.config/argon/sandbox.toml`
- `$HOME/.config/argon/sandbox.json`

Print the resolved paths with:

```bash
argon sandbox config paths --repo <repo>
argon sandbox config paths --repo <repo> --json
```

## Merge Rules

The final policy is built in this order:

1. built-in defaults, if enabled
2. user config base section
3. user config OS-specific section
4. repo config base section
5. repo config OS-specific section
6. explicit `--write-root` values passed to `argon sandbox exec`

`include_defaults` decides whether step 1 runs. The winning value is chosen by
this precedence order:

1. repo OS-specific section
2. repo base section
3. user OS-specific section
4. user base section
5. implicit default: `true`

So repo policy can tighten or replace the default allow-list for that repo.

## Config Schema

Shared top-level fields:

- `include_defaults`
  - `true` to keep Argon's built-in defaults
  - `false` to remove them and rely only on explicit config plus launch roots
- `write_paths`
  - exact writable paths
- `write_roots`
  - writable directory roots; everything under each root is writable

OS-specific sections currently supported:

- `macos`
- `linux`
- `windows`

Example repo config:

```yaml
include_defaults: true
write_roots:
  - ~/.claude.json.lock
  - .direnv
  - .build
write_paths:
  - /dev/null
  - $HOME/.claude.json

macos:
  write_roots:
    - .swiftpm
```

Equivalent TOML:

```toml
include_defaults = true
write_roots = [".direnv", ".build"]
write_paths = ["/dev/null"]

[macos]
write_roots = [".swiftpm"]
```

Notes:

- repo config paths may be relative to the repo root
- user config paths must resolve to absolute paths
- `~`, `$HOME`, and `${HOME}` are expanded in config paths and in
  `argon sandbox config add-write-*` commands
- device nodes are expressed as exact `write_paths`, for example `/dev/null`

## Programmatic Editing

Argon exposes config editing through `argon sandbox config`.

Examples:

```bash
argon sandbox config set-defaults --scope repo --enabled --repo <repo>
argon sandbox config set-defaults --scope repo --target macos --repo <repo>

argon sandbox config add-write-root --scope repo .direnv --repo <repo>
argon sandbox config add-write-root --scope repo .swiftpm --target macos --repo <repo>
argon sandbox config add-write-path --scope repo /dev/null --repo <repo>

argon sandbox config add-write-root --scope user ~/.cache
argon sandbox config remove-write-root --scope user '$HOME/.cache'
```

When a config file does not exist yet, Argon creates one. The default creation
format is YAML, but you can override it with `--format yaml|yml|toml|json`.

## `argon sandbox exec`

`argon sandbox exec` is the low-level command that applies the sandbox to the
current process and then `exec`s the requested command.

If you omit `--write-root`, Argon defaults to making the current working
directory writable.

Example:

```bash
argon sandbox exec \
  --repo-root /path/to/repo \
  --write-root /path/to/repo \
  --write-root /path/to/repo/.argon/sessions \
  -- /bin/sh -lc 'touch file-in-repo'
```

Default-to-current-directory example:

```bash
cd /path/to/repo
argon sandbox exec -- claude
```

This command is public because it is useful for testing and debugging, but it
is also the primitive used internally when Argon launches sandboxed reviewer
agents.

## Choosing User vs Repo Config

Use repo config when the writable exception is required by the project:

- `.direnv`
- `.swiftpm`
- `.build`
- project-local tool state

Use user config when the writable exception belongs to your machine-wide shell
or toolchain setup:

- global cache directories
- global state directories
- user-level tool data

That split keeps project policy versioned while still letting each developer
make local accommodations for their own environment.
