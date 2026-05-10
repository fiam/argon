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
    SandboxfileHelpContent.promptMessage(for: launchKind.displayName)
  }
}

func renderSandboxfile() -> String {
  renderSandboxfile(kind: .project)
}

func renderSandboxfile(kind: SandboxfileScaffoldKind) -> String {
  SandboxfileHelpContent.scaffold(for: kind)
}

func sandboxfilePromptIfNeeded(
  repoRoot: String,
  launchKind: SandboxfileLaunchKind,
  paths: ArgonCLI.SandboxConfigPaths
) -> SandboxfilePromptRequest? {
  let repoSandboxfilePath =
    paths.initPath
    ?? URL(fileURLWithPath: repoRoot).appendingPathComponent("Sandboxfile").path
  guard !paths.hasProjectSandboxfile(at: repoSandboxfilePath) else { return nil }

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
func createRepoSandboxfile(
  request: SandboxfilePromptRequest,
  configuration: SandboxfileWizardConfiguration = .recommended
) async throws {
  try await createSandboxfile(
    atPath: request.repoSandboxfilePath,
    contents: configuration.renderProjectSandboxfile()
  )
}

@MainActor
func createSandboxfile(
  atPath path: String,
  kind: SandboxfileScaffoldKind
) async throws {
  try await createSandboxfile(atPath: path, contents: renderSandboxfile(kind: kind))
}

@MainActor
func createSandboxfile(
  atPath path: String,
  contents: String
) async throws {
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

extension ArgonCLI.SandboxConfigPaths {
  fileprivate func hasProjectSandboxfile(at repoSandboxfilePath: String) -> Bool {
    let repoSandboxfileDirectory = URL(fileURLWithPath: repoSandboxfilePath)
      .deletingLastPathComponent()
      .standardizedFileURL
      .path

    return existingPaths.contains { path in
      URL(fileURLWithPath: path)
        .deletingLastPathComponent()
        .standardizedFileURL
        .path == repoSandboxfileDirectory
    }
  }
}

@MainActor
func saveSandboxfile(
  atPath path: String,
  contents: String
) async throws {
  try await Task.detached(priority: .userInitiated) {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: nil
    )
    try Data(contents.utf8).write(to: url, options: .atomic)
  }.value
}
