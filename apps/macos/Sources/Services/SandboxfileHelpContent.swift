import Foundation

enum SandboxfileHelpContent {
  static let docsURL = URL(string: "https://github.com/fiam/argon/blob/main/SANDBOX.md")!

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
    • the built-in `os`, `shell`, and `agent` modules
    • an optional `Sandboxfile.local` include for local overrides

    `USE os` allows access to the operating system's shared filesystem and runtime files used by shells and agents without exposing your personal directories.

    \(homeSandboxfileNote)

    The generated `Sandboxfile` includes a link to its docs at the top, and you can customize it later by editing `Sandboxfile`.
    """
  }

  static var defaultScaffold: String {
    [
      "# This file describes the Argon Sandbox configuration",
      "# Full docs: https://github.com/fiam/argon/blob/main/SANDBOX.md",
      "",
      "ENV DEFAULT NONE # Start from a minimal process environment by default.",
      "FS DEFAULT NONE # Start from no filesystem access by default.",
      "EXEC DEFAULT ALLOW # Allow running any command by default.",
      "FS ALLOW READ . # Allow reading files inside this repository.",
      "FS ALLOW WRITE . # Allow edits inside this repository.",
      "USE os # Allow access to the operating system's shared filesystem without exposing personal directories.",
      "USE shell # Allow the current shell binary and shell history when they apply.",
      "USE agent # Load agent-specific config and state when they apply.",
      "IF TEST -f ./Sandboxfile.local # Check for an optional repo-local sandbox extension file.",
      "    USE ./Sandboxfile.local",
      "END",
      "",
    ].joined(separator: "\n")
  }

  static let commandExamples =
    """
    argon --repo <repo> sandbox config paths
    argon sandbox check --repo-root <repo>
    argon sandbox explain --repo-root <repo>
    argon sandbox builtin print shell
    """
}
