import Darwin
import Foundation

struct SandboxedProcessSpec {
  let executable: String
  let args: [String]
}

enum UserShell {
  static func resolvedPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    if let shell = environment["SHELL"], !shell.isEmpty {
      return shell
    }

    if let entry = getpwuid(getuid()), let shellPointer = entry.pointee.pw_shell,
      shellPointer.pointee != 0
    {
      return String(cString: shellPointer)
    }

    return "/bin/zsh"
  }

  static func launchSpec(
    command: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> SandboxedProcessSpec {
    SandboxedProcessSpec(
      executable: resolvedPath(environment: environment),
      args: ["-i", "-l", "-c", command]
    )
  }

  static func commandExists(
    _ command: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    commandStatuses([command], environment: environment)[command] == true
  }

  static func commandStatuses(
    _ commands: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: Bool] {
    let uniqueCommands = Array(
      Set(
        commands.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    )
    guard !uniqueCommands.isEmpty else { return [:] }

    let process = Process()
    let script =
      uniqueCommands
      .map { command in
        let quoted = shellQuote(command)
        return """
          if command -v -- \(quoted) >/dev/null 2>&1; then
            printf '%s\\t1\\n' \(quoted)
          else
            printf '%s\\t0\\n' \(quoted)
          fi
          """
      }
      .joined(separator: "\n")
    let launch = launchSpec(command: script, environment: environment)
    process.executableURL = URL(fileURLWithPath: launch.executable)
    process.arguments = launch.args
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do {
      try process.run()
      let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        return Dictionary(uniqueKeysWithValues: uniqueCommands.map { ($0, false) })
      }

      let output = String(data: outputData, encoding: .utf8) ?? ""
      var results: [String: Bool] = [:]
      for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        results[String(parts[0])] = parts[1] == "1"
      }
      for command in uniqueCommands where results[command] == nil {
        results[command] = false
      }
      return results
    } catch {
      return Dictionary(uniqueKeysWithValues: uniqueCommands.map { ($0, false) })
    }
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}
