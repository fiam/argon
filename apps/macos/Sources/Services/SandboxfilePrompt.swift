import Foundation

enum SandboxfileLaunchKind: String, Sendable {
  case shell
  case agent
  case reviewer

  var displayName: String {
    switch self {
    case .shell:
      "sandboxed shell"
    case .agent:
      "sandboxed agent"
    case .reviewer:
      "sandboxed reviewer"
    }
  }
}

struct SandboxfilePromptRequest: Identifiable, Equatable, Sendable {
  let id = UUID()
  let repoRoot: String
  let repoSandboxfilePath: String
  let launchKind: SandboxfileLaunchKind

  var title: String {
    "Create Sandboxfile?"
  }

  var confirmTitle: String {
    "Create and Launch"
  }

  var message: String {
    """
    Argon needs a Sandboxfile before launching this \(launchKind.displayName).

    The default Sandboxfile starts from a minimal environment and no filesystem access, then adds:
    • read and write access to this repository
    • the built-in `os`, `shell`, and `agent` modules
    • an optional `Sandboxfile.local` include for local overrides

    `USE os` allows access to the operating system's shared filesystem and runtime files used by shells and agents without exposing your personal directories.

    The generated `Sandboxfile` includes a link to its docs at the top, and you can customize it later by editing `Sandboxfile`.
    """
  }
}

func renderSandboxfile() -> String {
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

func sandboxfilePromptIfNeeded(
  repoRoot: String,
  launchKind: SandboxfileLaunchKind,
  paths: ArgonCLI.SandboxConfigPaths
) -> SandboxfilePromptRequest? {
  guard paths.existingPaths.isEmpty else { return nil }
  let repoSandboxfilePath =
    paths.initPath
    ?? URL(fileURLWithPath: repoRoot).appendingPathComponent("Sandboxfile").path
  return SandboxfilePromptRequest(
    repoRoot: repoRoot,
    repoSandboxfilePath: repoSandboxfilePath,
    launchKind: launchKind
  )
}

@MainActor
func loadSandboxfilePromptIfNeeded(
  repoRoot: String,
  launchKind: SandboxfileLaunchKind
) async throws -> SandboxfilePromptRequest? {
  let paths = try await Task.detached(priority: .userInitiated) {
    try ArgonCLI.sandboxConfigPaths(repoRoot: repoRoot)
  }.value
  return sandboxfilePromptIfNeeded(repoRoot: repoRoot, launchKind: launchKind, paths: paths)
}

@MainActor
func createRepoSandboxfile(request: SandboxfilePromptRequest) async throws {
  let path = request.repoSandboxfilePath
  let contents = renderSandboxfile()
  try await Task.detached(priority: .userInitiated) {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: nil
    )
    do {
      try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
    } catch CocoaError.fileWriteFileExists {
      return
    }
  }.value
}
