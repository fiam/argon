import Darwin
import Foundation

struct ArgonTerminalSessionBackend: TerminalSessionBackend {
  let backendID = "argon"
  private static let storageDirectoryContextKey = "storageDir"

  func isAvailable() -> Bool {
    FileManager.default.isExecutableFile(atPath: ArgonCLI.cliPath())
  }

  func reference(for tabID: UUID, projectPath: String) -> TerminalSessionReference? {
    return TerminalSessionReference(
      backendID: backendID,
      sessionID: "argon-\(tabID.uuidString.lowercased())",
      context: [
        Self.storageDirectoryContextKey: Self.storageDirectory(projectPath: projectPath).path
      ]
    )
  }

  func attachLaunchConfiguration(
    reference: TerminalSessionReference,
    createLaunch: TerminalLaunchConfiguration
  ) -> TerminalLaunchConfiguration {
    let cli = ArgonCLI.cliPath()
    let storageDirectory = Self.storageDirectory(
      reference: reference,
      fallbackProjectPath: createLaunch.currentDirectory
    ).path
    let args = [
      cli,
      "terminal",
      "attach",
      "--session-id",
      reference.sessionID,
      "--storage-dir",
      storageDirectory,
      "--no-replay",
      "--",
      "/bin/sh",
      "-lc",
      createLaunch.shellCommand,
    ]
    TerminalSessionLifecycleLog.record(
      "attach-launch session=\(reference.sessionID) storage=\(storageDirectory) cwd=\(createLaunch.currentDirectory) command=\(createLaunch.shellCommand)"
    )
    return TerminalLaunchConfiguration.command(
      args.map(TerminalLaunchConfiguration.shellQuote).joined(separator: " "),
      currentDirectory: createLaunch.currentDirectory,
      environment: createLaunch.environment
    )
  }

  func stop(reference: TerminalSessionReference) {
    guard reference.backendID == backendID else { return }
    TerminalSessionLifecycleLog.record("backend-stop session=\(reference.sessionID)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ArgonCLI.cliPath())
    process.arguments = [
      "terminal",
      "stop",
      "--session-id",
      reference.sessionID,
      "--storage-dir",
      Self.storageDirectory(reference: reference).path,
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return }
    process.waitUntilExit()
  }

  func isRunning(reference: TerminalSessionReference) -> Bool {
    guard reference.backendID == backendID else { return false }

    let paths = sessionPaths(reference: reference)
    guard FileManager.default.fileExists(atPath: paths.socket.path) else {
      TerminalSessionLifecycleLog.record(
        "backend-is-running session=\(reference.sessionID) result=false reason=missing-socket"
      )
      return false
    }
    guard
      let pidText = try? String(contentsOf: paths.pid, encoding: .utf8),
      let parsedPID = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
      parsedPID > 0
    else {
      TerminalSessionLifecycleLog.record(
        "backend-is-running session=\(reference.sessionID) result=false reason=missing-pid"
      )
      return false
    }
    let pid = pid_t(parsedPID)

    if kill(pid, 0) == 0 {
      return true
    }
    let running = errno == EPERM
    if !running {
      TerminalSessionLifecycleLog.record(
        "backend-is-running session=\(reference.sessionID) result=false reason=dead-pid pid=\(parsedPID)"
      )
    }
    return running
  }

  private func sessionPaths(reference: TerminalSessionReference) -> (socket: URL, pid: URL) {
    let directory = Self.storageDirectory(reference: reference)
    return (
      socket: directory.appendingPathComponent("\(reference.sessionID).sock", isDirectory: false),
      pid: directory.appendingPathComponent("\(reference.sessionID).pid", isDirectory: false)
    )
  }

  private static func storageDirectory(
    reference: TerminalSessionReference,
    fallbackProjectPath: String? = nil
  ) -> URL {
    if let path = reference.context[storageDirectoryContextKey], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    if let fallbackProjectPath, !fallbackProjectPath.isEmpty {
      return storageDirectory(projectPath: fallbackProjectPath)
    }
    return legacyStorageDirectory()
  }

  private static func storageDirectory(projectPath: String) -> URL {
    compactRootDirectory()
      .appendingPathComponent("p-\(projectHash(projectPath))", isDirectory: true)
  }

  private static func compactRootDirectory() -> URL {
    URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("argon-ts-\(getuid())", isDirectory: true)
  }

  private static func legacyStorageDirectory() -> URL {
    URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("argon-terminal-sessions-\(getuid())", isDirectory: true)
  }

  private static func projectHash(_ projectPath: String) -> String {
    let resolved = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    let hash = fnv1a64(Array(resolved.utf8))
    return String(format: "%016llx", hash)
  }

  private static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return hash
  }

}

struct LegacyScreenTerminalSessionStopper: Sendable {
  let backendID = "screen"

  func stop(reference: TerminalSessionReference) {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/screen") else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/screen")
    process.arguments = [
      "-U",
      "-q",
      "-S",
      reference.sessionID,
      "-X",
      "quit",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["SCREENDIR"] = legacySocketDirectory().path
    process.environment = environment
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return }
    process.waitUntilExit()
  }

  private func legacySocketDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?
      .appendingPathComponent("Argon", isDirectory: true)
      .appendingPathComponent("TerminalSessions", isDirectory: true)
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("Argon", isDirectory: true)
      .appendingPathComponent("TerminalSessions", isDirectory: true)

    return base.appendingPathComponent("screen-sockets", isDirectory: true)
  }
}
