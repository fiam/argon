import Darwin
import Foundation

struct ArgonTerminalSessionBackend: TerminalSessionBackend {
  let backendID = "argon"

  func isAvailable() -> Bool {
    FileManager.default.isExecutableFile(atPath: ArgonCLI.cliPath())
  }

  func reference(for tabID: UUID, workspacePath: String) -> TerminalSessionReference? {
    TerminalSessionReference(
      backendID: backendID,
      sessionID: "argon-\(tabID.uuidString.lowercased())",
      context: [
        TerminalSessionReferenceContextKey.storageDirectory:
          Self.storageDirectory(workspacePath: workspacePath).path
      ]
    )
  }

  func attachLaunchConfiguration(
    reference: TerminalSessionReference,
    createLaunch: TerminalLaunchConfiguration
  ) -> TerminalLaunchConfiguration {
    guard let storageDirectory = Self.storageDirectory(for: reference) else {
      TerminalSessionLifecycleLog.record(
        "attach-launch-skipped session=\(reference.sessionID) reason=missing-storage-directory"
      )
      return createLaunch
    }

    let cli = ArgonCLI.cliPath()
    let storageDirectoryPath = storageDirectory.path
    let args = [
      cli,
      "terminal",
      "attach",
      "--session-id",
      reference.sessionID,
      "--storage-dir",
      storageDirectoryPath,
      "--no-replay",
      "--",
      "/bin/sh",
      "-lc",
      createLaunch.shellCommand,
    ]
    TerminalSessionLifecycleLog.record(
      "attach-launch session=\(reference.sessionID) storage=\(storageDirectoryPath) cwd=\(createLaunch.currentDirectory) command=\(createLaunch.shellCommand)"
    )
    return TerminalLaunchConfiguration.command(
      args.map(TerminalLaunchConfiguration.shellQuote).joined(separator: " "),
      currentDirectory: createLaunch.currentDirectory,
      environment: createLaunch.environment
    )
  }

  func stop(reference: TerminalSessionReference) {
    guard reference.backendID == backendID else { return }
    guard let storageDirectory = Self.storageDirectory(for: reference) else {
      TerminalSessionLifecycleLog.record(
        "backend-stop-skipped session=\(reference.sessionID) reason=missing-storage-directory"
      )
      return
    }
    TerminalSessionLifecycleLog.record("backend-stop session=\(reference.sessionID)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ArgonCLI.cliPath())
    process.arguments = [
      "terminal",
      "stop",
      "--session-id",
      reference.sessionID,
      "--storage-dir",
      storageDirectory.path,
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return }
    process.waitUntilExit()
  }

  func isRunning(reference: TerminalSessionReference) -> Bool {
    guard reference.backendID == backendID else { return false }
    guard canReconnect(reference: reference) else {
      TerminalSessionLifecycleLog.record(
        "backend-is-running session=\(reference.sessionID) result=false reason=missing-storage-directory"
      )
      return false
    }

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

  func canReconnect(reference: TerminalSessionReference) -> Bool {
    reference.backendID == backendID
      && isAvailable()
      && Self.storageDirectory(for: reference) != nil
  }

  private func sessionPaths(reference: TerminalSessionReference) -> (socket: URL, pid: URL) {
    let directory = Self.storageDirectory(for: reference)!
    return (
      socket: directory.appendingPathComponent("\(reference.sessionID).sock", isDirectory: false),
      pid: directory.appendingPathComponent("\(reference.sessionID).pid", isDirectory: false)
    )
  }

  private static func storageDirectory(for reference: TerminalSessionReference) -> URL? {
    guard
      let storageDirectory = reference.context[TerminalSessionReferenceContextKey.storageDirectory],
      !storageDirectory.isEmpty
    else {
      return nil
    }

    return URL(fileURLWithPath: storageDirectory, isDirectory: true)
  }

  private static func storageDirectory(workspacePath: String) -> URL {
    compactRootDirectory()
      .appendingPathComponent("p-\(pathHash(workspacePath))", isDirectory: true)
  }

  private static func compactRootDirectory() -> URL {
    URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("argon-ts-\(getuid())", isDirectory: true)
  }

  private static func pathHash(_ path: String) -> String {
    let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
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
