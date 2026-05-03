import Darwin
import Foundation

struct ArgonTerminalSessionBackend: TerminalSessionBackend {
  let backendID = "argon"

  func isAvailable() -> Bool {
    FileManager.default.isExecutableFile(atPath: ArgonCLI.cliPath())
  }

  func reference(for tabID: UUID) -> TerminalSessionReference? {
    guard isAvailable() else { return nil }
    return TerminalSessionReference(
      backendID: backendID,
      sessionID: "argon-\(tabID.uuidString.lowercased())"
    )
  }

  func attachLaunchConfiguration(
    reference: TerminalSessionReference,
    createLaunch: TerminalLaunchConfiguration
  ) -> TerminalLaunchConfiguration {
    let cli = ArgonCLI.cliPath()
    let args = [
      cli,
      "terminal",
      "attach",
      "--session-id",
      reference.sessionID,
      "--no-replay",
      "--",
      "/bin/sh",
      "-lc",
      createLaunch.shellCommand,
    ]
    TerminalSessionLifecycleLog.record(
      "attach-launch session=\(reference.sessionID) cwd=\(createLaunch.currentDirectory) command=\(createLaunch.shellCommand)"
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
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-terminal-sessions-\(getuid())", isDirectory: true)
    return (
      socket: directory.appendingPathComponent("\(reference.sessionID).sock", isDirectory: false),
      pid: directory.appendingPathComponent("\(reference.sessionID).pid", isDirectory: false)
    )
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
