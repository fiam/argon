import Foundation

enum SandboxfileScaffoldKind: String, Sendable {
  case project
  case personal

  var titleLine: String {
    switch self {
    case .project:
      "# This file describes the Argon Sandbox project configuration"
    case .personal:
      "# This file describes the Argon Sandbox personal configuration"
    }
  }
}

enum SandboxfileNetworkDefault: String, CaseIterable, Identifiable, Sendable {
  case allow
  case proxy
  case none

  var id: String { rawValue }

  var title: String {
    switch self {
    case .allow:
      "Allow"
    case .proxy:
      "Proxy"
    case .none:
      "Block"
    }
  }

  var sandboxLines: [String] {
    switch self {
    case .allow:
      ["NET DEFAULT ALLOW # Allow outbound network access by default."]
    case .proxy:
      [
        "NET DEFAULT NONE # Block direct outbound network access by default.",
        "NET ALLOW PROXY * # Route proxy-aware HTTP(S) traffic through Argon's local proxy.",
      ]
    case .none:
      ["NET DEFAULT NONE # Block outbound network access by default."]
    }
  }
}

enum SandboxfileExecDefault: String, CaseIterable, Identifiable, Sendable {
  case allow
  case deny

  var id: String { rawValue }

  var title: String {
    switch self {
    case .allow:
      "Allow"
    case .deny:
      "Deny"
    }
  }

  var sandboxLine: String {
    switch self {
    case .allow:
      "EXEC DEFAULT ALLOW # Allow running any command by default."
    case .deny:
      "EXEC DEFAULT DENY # Only allow explicitly listed commands by default."
    }
  }
}

struct SandboxfileWizardBuiltin: Equatable, Identifiable, Sendable {
  let name: String
  let detail: String
  let sandboxComment: String

  var id: String { name }

  var sandboxLine: String {
    "USE \(name) # \(sandboxComment)"
  }

  // Keep this recommended new-project subset valid against
  // crates/sandbox/src/builtins.rs and aligned with default_sandboxfile_template
  // in crates/sandbox/src/lib.rs. Nested and opt-in builtins should only be
  // added here when new project Sandboxfiles should include them by default.
  static let projectDefaults = [
    SandboxfileWizardBuiltin(
      name: "os",
      detail: "Shared system files required by shells and tools.",
      sandboxComment:
        "Allow access to the operating system's shared filesystem without exposing personal directories."
    ),
    SandboxfileWizardBuiltin(
      name: "git",
      detail: "Git executable, config, and linked worktree metadata.",
      sandboxComment: "Allow git, standard git config, and linked worktree Git directories."
    ),
    SandboxfileWizardBuiltin(
      name: "shell",
      detail: "Current shell binary and shell history, when present.",
      sandboxComment: "Allow the current shell binary and shell history when they apply."
    ),
    SandboxfileWizardBuiltin(
      name: "agent",
      detail: "Agent-specific config and state for installed tools.",
      sandboxComment: "Load agent-specific config and state when they apply."
    ),
  ]
}

struct SandboxfileWizardConfiguration: Equatable, Sendable {
  var executionDefault: SandboxfileExecDefault = .allow
  var networkDefault: SandboxfileNetworkDefault = .allow
  var allowRepositoryRead = true
  var allowRepositoryWrite = true
  var selectedBuiltinNames = SandboxfileWizardBuiltin.projectDefaults.map(\.name)
  var includeLocalOverrides = true

  static let recommended = Self()

  func includesBuiltin(_ builtin: SandboxfileWizardBuiltin) -> Bool {
    selectedBuiltinNames.contains(builtin.name)
  }

  mutating func setBuiltin(_ builtin: SandboxfileWizardBuiltin, isEnabled: Bool) {
    if isEnabled {
      if !selectedBuiltinNames.contains(builtin.name) {
        selectedBuiltinNames.append(builtin.name)
      }
    } else {
      selectedBuiltinNames.removeAll { $0 == builtin.name }
    }
  }

  func renderProjectSandboxfile() -> String {
    var lines = [
      SandboxfileScaffoldKind.project.titleLine,
      "# Full docs: https://github.com/fiam/argon/blob/main/SANDBOX.md",
      "",
      "ENV DEFAULT NONE # Start from a minimal process environment by default.",
      "FS DEFAULT NONE # Start from no filesystem access by default.",
      executionDefault.sandboxLine,
    ]
    lines += networkDefault.sandboxLines

    if allowRepositoryRead {
      lines.append("FS ALLOW READ . # Allow reading files inside this repository.")
    }
    if allowRepositoryWrite {
      lines.append("FS ALLOW WRITE . # Allow edits inside this repository.")
    }

    for builtin in SandboxfileWizardBuiltin.projectDefaults where includesBuiltin(builtin) {
      lines.append(builtin.sandboxLine)
    }

    if includeLocalOverrides {
      lines += [
        "IF TEST -f ./Sandboxfile.local # Check for an optional repo-local sandbox extension file.",
        "    USE ./Sandboxfile.local",
        "END",
      ]
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }
}

enum SandboxfileHelpContent {
  static let docsURL = URL(string: "https://github.com/fiam/argon/blob/main/SANDBOX.md")!
  static let highlightPath = "sandbox.sh"

  static let homeSandboxfileNote =
    "You can also create `$HOME/.Sandboxfile` for user-level policy. Argon walks parent directories upward, so the home-level file applies after repo-local `Sandboxfile` files and any `./Sandboxfile.local` include."

  static let settingsOverview =
    """
    Argon discovers sandbox policy by walking parent directories upward from the launch directory.

    A repository usually starts with a local `Sandboxfile`, may optionally include `./Sandboxfile.local`, and can also use `$HOME/.Sandboxfile` for user-level policy that should apply after the repo-local sandbox files.
    """

  static func promptMessage(for launchDisplayName: String) -> String {
    """
    Argon needs a Sandboxfile before launching this \(launchDisplayName).

    The default Sandboxfile starts from a minimal environment and no filesystem access, then adds:
    • read and write access to this repository
    • the built-in `os`, `git`, `shell`, and `agent` modules
    • an optional `Sandboxfile.local` include for local overrides

    `USE os` allows access to the operating system's shared filesystem and runtime files used by shells and agents without exposing your personal directories.

    \(homeSandboxfileNote)

    The generated `Sandboxfile` includes a link to its docs at the top, and you can customize it later by editing `Sandboxfile`.
    """
  }

  static func scaffold(for kind: SandboxfileScaffoldKind) -> String {
    switch kind {
    case .project:
      return SandboxfileWizardConfiguration.recommended.renderProjectSandboxfile()

    case .personal:
      return [
        kind.titleLine,
        "# Full docs: https://github.com/fiam/argon/blob/main/SANDBOX.md",
        "",
        "# Add user-specific rules here for tools your shell or agent needs,",
        "# for example `starship`, `atuin`, or other local helpers.",
        "",
      ].joined(separator: "\n")
    }
  }

  static var defaultScaffold: String {
    scaffold(for: .project)
  }

  static let commandExamples =
    """
    argon --repo <repo> sandbox config paths
    argon sandbox check --repo-root <repo>
    argon sandbox explain --repo-root <repo>
    argon sandbox builtin print shell
    """
}
