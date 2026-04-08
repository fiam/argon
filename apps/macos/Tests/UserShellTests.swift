import Foundation
import Testing

@testable import Argon

@Suite("UserShell")
struct UserShellTests {

  @Test("launch spec prefers the environment shell")
  func launchSpecPrefersEnvironmentShell() {
    let spec = UserShell.launchSpec(
      command: "echo hello",
      environment: ["SHELL": "/opt/custom/bin/zsh"]
    )

    #expect(spec.executable == "/opt/custom/bin/zsh")
    #expect(spec.args == ["-i", "-l", "-c", "echo hello"])
  }

  @Test("commandExists invokes the user shell with login interactive flags")
  func commandExistsUsesLoginInteractiveShell() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let logPath = tempDir.appendingPathComponent("shell.log")
    let shellPath = tempDir.appendingPathComponent("fake-shell.sh")
    let script = """
      #!/bin/sh
      printf '%s\\n' "$@" > "\(logPath.path)"
      printf 'codex\\t1\\n'
      exit 0
      """
    try script.write(to: shellPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: shellPath.path
    )

    let exists = UserShell.commandExists(
      "codex",
      environment: ["SHELL": shellPath.path]
    )

    #expect(exists)

    let loggedArgs = try String(contentsOf: logPath, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
    #expect(loggedArgs.count >= 4)
    #expect(loggedArgs[0] == "-i")
    #expect(loggedArgs[1] == "-l")
    #expect(loggedArgs[2] == "-c")
    #expect(loggedArgs.dropFirst(3).joined(separator: "\n").contains("command -v -- 'codex'"))
  }

  @Test("commandStatuses checks multiple commands in one shell launch")
  func commandStatusesChecksCommandsInOneLaunch() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let countPath = tempDir.appendingPathComponent("count")
    let shellPath = tempDir.appendingPathComponent("fake-shell.sh")
    let script = """
      #!/bin/sh
      count=0
      if [ -f "\(countPath.path)" ]; then
        count=$(cat "\(countPath.path)")
      fi
      count=$((count + 1))
      printf '%s' "$count" > "\(countPath.path)"
      printf 'claude\\t1\\n'
      printf 'codex\\t0\\n'
      exit 0
      """
    try script.write(to: shellPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: shellPath.path
    )

    let statuses = UserShell.commandStatuses(
      ["claude", "codex"],
      environment: ["SHELL": shellPath.path]
    )

    #expect(statuses["claude"] == true)
    #expect(statuses["codex"] == false)
    #expect(try String(contentsOf: countPath, encoding: .utf8) == "1")
  }
}
