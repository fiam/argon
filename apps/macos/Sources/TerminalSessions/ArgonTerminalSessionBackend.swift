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

  func attachCommand(reference: TerminalSessionReference, createCommand: String) -> String {
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
      createCommand,
    ]
    return args.map(Self.shellQuote).joined(separator: " ")
  }

  func stop(reference: TerminalSessionReference) {
    guard reference.backendID == backendID else { return }
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

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
