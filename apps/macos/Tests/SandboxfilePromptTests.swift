import Foundation
import Testing

@testable import Argon

@Suite("SandboxfilePrompt")
struct SandboxfilePromptTests {
  @Test("prompt is produced when no ancestor Sandboxfile exists")
  func promptIsProducedWhenNoAncestorSandboxfileExists() {
    let paths = ArgonCLI.SandboxConfigPaths(
      initPath: "/tmp/repo/Sandboxfile",
      entries: [],
      existingPaths: []
    )

    let prompt = sandboxfilePromptIfNeeded(
      repoRoot: "/tmp/repo",
      launchKind: .shell,
      paths: paths
    )

    #expect(prompt?.repoSandboxfilePath == "/tmp/repo/Sandboxfile")
    #expect(prompt?.launchKind == .shell)
    #expect(prompt?.message.contains("sandboxed shell") == true)
    #expect(prompt?.message.contains("repo Sandboxfile") == false)
    #expect(prompt?.message.contains("customize it later by editing `Sandboxfile`") == true)
    #expect(prompt?.message.contains("shells and agents") == true)
    #expect(prompt?.message.contains("includes a link to its docs") == true)
    #expect(prompt?.message.contains("$HOME/.Sandboxfile") == true)
  }

  @Test("prompt is skipped when any ancestor Sandboxfile already exists")
  func promptIsSkippedWhenAncestorSandboxfileAlreadyExists() {
    let paths = ArgonCLI.SandboxConfigPaths(
      initPath: "/tmp/repo/Sandboxfile",
      entries: [
        ArgonCLI.SandboxConfigEntry(
          directory: "/tmp/home",
          sandboxfilePath: "/tmp/home/Sandboxfile",
          dotSandboxfilePath: "/tmp/home/.Sandboxfile",
          compatibilityPath: "/tmp/home/.Sanboxfile",
          existingPath: "/tmp/home/.Sandboxfile"
        )
      ],
      existingPaths: ["/tmp/home/.Sandboxfile"]
    )

    let prompt = sandboxfilePromptIfNeeded(
      repoRoot: "/tmp/repo",
      launchKind: .agent,
      paths: paths
    )

    #expect(prompt == nil)
  }

  @Test("renderSandboxfile uses the recommended default scaffold")
  func renderSandboxfileUsesRecommendedDefaultScaffold() {
    let rendered = renderSandboxfile()

    #expect(rendered.contains("# This file describes the Argon Sandbox configuration"))
    #expect(
      rendered.contains("ENV DEFAULT NONE # Start from a minimal process environment by default."))
    #expect(rendered.contains("FS DEFAULT NONE # Start from no filesystem access by default."))
    #expect(
      rendered.contains(
        "EXEC DEFAULT ALLOW # Allow running any command by default."))
    #expect(rendered.contains("FS ALLOW READ . # Allow reading files inside this repository."))
    #expect(rendered.contains("FS ALLOW WRITE . # Allow edits inside this repository."))
    #expect(
      rendered.contains(
        "USE os # Allow access to the operating system's shared filesystem without exposing personal directories."
      ))
    #expect(
      rendered.contains(
        "USE shell # Allow the current shell binary and shell history when they apply."))
    #expect(
      rendered.contains(
        "USE agent # Load agent-specific config and state when they apply."))
    #expect(rendered.contains("    USE ./Sandboxfile.local\nEND"))
  }

  @Test("createRepoSandboxfile writes the default scaffold")
  @MainActor
  func createRepoSandboxfileWritesDefaultScaffold() async throws {
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "argon-sandboxfile-prompt-tests-\(UUID().uuidString)"
    )
    defer {
      try? FileManager.default.removeItem(at: tempDirectory)
    }

    let request = SandboxfilePromptRequest(
      repoRoot: tempDirectory.path,
      repoSandboxfilePath: tempDirectory.appendingPathComponent("Sandboxfile").path,
      launchKind: .shell
    )

    try await createRepoSandboxfile(request: request)

    let contents = try String(
      contentsOf: tempDirectory.appendingPathComponent("Sandboxfile"),
      encoding: .utf8
    )
    #expect(contents.contains("FS ALLOW READ . # Allow reading files inside this repository."))
    #expect(
      contents.contains(
        "EXEC DEFAULT ALLOW # Allow running any command by default."))
    #expect(
      contents.contains(
        "USE shell # Allow the current shell binary and shell history when they apply."))
    #expect(
      contents.contains(
        "USE agent # Load agent-specific config and state when they apply."))
    #expect(
      !FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent(".argon").path))
  }
}
