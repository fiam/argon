import Darwin
import Foundation
import Testing

@testable import Argon

@Suite("ArgonTerminalSessionBackend")
struct ArgonTerminalSessionBackendTests {

  @Test("isRunning ignores unscoped references")
  func isRunningIgnoresUnscopedReferences() throws {
    let backend = ArgonTerminalSessionBackend()
    let sessionID = "argon-test-\(UUID().uuidString.lowercased())"
    let storageDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("argon-terminal-sessions-\(getuid())", isDirectory: true)
    let socketPath = storageDirectory.appendingPathComponent("\(sessionID).sock")
    let pidPath = storageDirectory.appendingPathComponent("\(sessionID).pid")

    try FileManager.default.createDirectory(
      at: storageDirectory,
      withIntermediateDirectories: true
    )
    try Data().write(to: socketPath)
    try "\(getpid())\n".write(to: pidPath, atomically: true, encoding: .utf8)
    defer {
      try? FileManager.default.removeItem(at: socketPath)
      try? FileManager.default.removeItem(at: pidPath)
    }

    #expect(
      !backend.isRunning(
        reference: TerminalSessionReference(backendID: "argon", sessionID: sessionID))
    )
    #expect(
      !backend.canReconnect(
        reference: TerminalSessionReference(backendID: "argon", sessionID: sessionID)))
  }

  @Test("isRunning honors the reference storage directory")
  func isRunningHonorsTheReferenceStorageDirectory() throws {
    let backend = ArgonTerminalSessionBackend()
    let sessionID = "argon-test-\(UUID().uuidString.lowercased())"
    let storageDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("argon-terminal-session-test-\(UUID().uuidString)", isDirectory: true)
    let socketPath = storageDirectory.appendingPathComponent("\(sessionID).sock")
    let pidPath = storageDirectory.appendingPathComponent("\(sessionID).pid")

    try FileManager.default.createDirectory(
      at: storageDirectory,
      withIntermediateDirectories: true
    )
    try Data().write(to: socketPath)
    try "\(getpid())\n".write(to: pidPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: storageDirectory) }

    #expect(
      backend.isRunning(
        reference: TerminalSessionReference(
          backendID: "argon",
          sessionID: sessionID,
          context: [
            TerminalSessionReferenceContextKey.storageDirectory: storageDirectory.path
          ]
        )
      )
    )
  }

  @Test("workspace references are scoped by workspace path")
  func workspaceReferencesAreScopedByWorkspacePath() throws {
    let backend = ArgonTerminalSessionBackend()
    let tabID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let firstReference = try #require(
      backend.reference(for: tabID, workspacePath: "/tmp/repo-a")
    )
    let secondReference = try #require(
      backend.reference(for: tabID, workspacePath: "/tmp/repo-b")
    )
    let firstDirectory = try #require(
      firstReference.context[TerminalSessionReferenceContextKey.storageDirectory]
    )
    let secondDirectory = try #require(
      secondReference.context[TerminalSessionReferenceContextKey.storageDirectory]
    )

    #expect(firstReference.sessionID == secondReference.sessionID)
    #expect(firstDirectory != secondDirectory)
    #expect(firstDirectory.hasPrefix("/tmp/argon-ts-\(getuid())/p-"))
    #expect(secondDirectory.hasPrefix("/tmp/argon-ts-\(getuid())/p-"))
  }

  @Test("attach passes the reference storage directory to the CLI")
  func attachPassesTheReferenceStorageDirectoryToTheCLI() {
    let storageDirectory = URL(fileURLWithPath: "/tmp/argon-session-scope-test", isDirectory: true)
    let launch = TerminalLaunchConfiguration.command(
      "codex",
      currentDirectory: "/tmp/repo",
      environment: [
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/zsh",
      ]
    )

    let attachedLaunch = ArgonTerminalSessionBackend().attachLaunchConfiguration(
      reference: TerminalSessionReference(
        backendID: "argon",
        sessionID: "argon-scoped",
        context: [
          TerminalSessionReferenceContextKey.storageDirectory: storageDirectory.path
        ]
      ),
      createLaunch: launch
    )

    let attachCommand = attachedLaunch.processSpec.args.last ?? ""
    #expect(attachedLaunch.environment["ARGON_TERMINAL_SESSION_DIR"] == nil)
    #expect(attachCommand.contains("'terminal' 'attach'"))
    #expect(attachCommand.contains("'--storage-dir' '\(storageDirectory.path)'"))
  }
}
