import Darwin
import Foundation

struct SandboxedProcessSpec {
  let executable: String
  let args: [String]
}

struct UserShellCommandDetails: Sendable {
  let exists: Bool
  let resolvedPath: String?
  let version: String?
}

enum UserShell {
  private struct InteractivePathCacheKey: Hashable {
    let shell: String
    let home: String?
    let path: String?
    let zdotdir: String?
  }

  private static let interactivePathCacheLock = NSLock()
  nonisolated(unsafe) private static var interactivePathCache: [InteractivePathCacheKey: String] =
    [:]
  private static let interactivePathProbeTimeout: TimeInterval = 2

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

  static func loginLaunchSpec(
    command: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> SandboxedProcessSpec {
    SandboxedProcessSpec(
      executable: resolvedPath(environment: environment),
      args: ["-l", "-c", command]
    )
  }

  static func interactiveLaunchSpec(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> SandboxedProcessSpec {
    SandboxedProcessSpec(
      executable: resolvedPath(environment: environment),
      args: ["-i", "-l"]
    )
  }

  static func environmentResolvingInteractivePath(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    guard let path = interactivePath(environment: environment) else {
      return environment
    }

    var resolvedEnvironment = environment
    resolvedEnvironment["PATH"] = path
    return resolvedEnvironment
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
    commandStatuses(commands, environment: environment, launch: launchSpec)
  }

  static func loginCommandStatuses(
    _ commands: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: Bool] {
    commandStatuses(commands, environment: environment, launch: loginLaunchSpec)
  }

  static func commandDetails(
    _ commandsByFamily: [String: AgentFamilyID?],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: UserShellCommandDetails] {
    commandDetails(commandsByFamily, environment: environment, launch: launchSpec)
  }

  private static func commandStatuses(
    _ commands: [String],
    environment: [String: String],
    launch: (String, [String: String]) -> SandboxedProcessSpec
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
    let processLaunch = launch(script, environment)
    process.executableURL = URL(fileURLWithPath: processLaunch.executable)
    process.arguments = processLaunch.args
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

  private static func commandDetails(
    _ commandsByFamily: [String: AgentFamilyID?],
    environment: [String: String],
    launch: (String, [String: String]) -> SandboxedProcessSpec
  ) -> [String: UserShellCommandDetails] {
    let commands = commandsByFamily.keys
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let uniqueCommands = Array(Set(commands))
    guard !uniqueCommands.isEmpty else { return [:] }

    let script =
      uniqueCommands
      .map { command in
        let quotedCommand = shellQuote(command)
        let versionArguments = commandsByFamily[command]??.harness.versionArguments ?? []
        let versionCommand =
          ([quotedCommand] + versionArguments.map(shellQuote)).joined(separator: " ")

        let versionProbe =
          versionArguments.isEmpty
          ? "version_output=''"
          : "version_output=$(\(versionCommand) 2>&1 | tr '\\011' ' ' | sed -n '/./{p;q;}')"

        return """
          if resolved=$(command -v -- \(quotedCommand) 2>/dev/null); then
            \(versionProbe)
            printf '%s\\t1\\t%s\\t%s\\n' \(quotedCommand) "$resolved" "$version_output"
          else
            printf '%s\\t0\\t\\t\\n' \(quotedCommand)
          fi
          """
      }
      .joined(separator: "\n")

    let process = Process()
    let processLaunch = launch(script, environment)
    process.executableURL = URL(fileURLWithPath: processLaunch.executable)
    process.arguments = processLaunch.args
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do {
      try process.run()
      let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        return Dictionary(
          uniqueKeysWithValues: uniqueCommands.map {
            ($0, UserShellCommandDetails(exists: false, resolvedPath: nil, version: nil))
          })
      }

      let output = String(data: outputData, encoding: .utf8) ?? ""
      var results: [String: UserShellCommandDetails] = [:]
      for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { continue }
        let command = String(parts[0])
        let exists = parts[1] == "1"
        let resolvedPath = String(parts[2]).nilIfEmpty
        let version = String(parts[3]).nilIfEmpty
        results[command] = UserShellCommandDetails(
          exists: exists,
          resolvedPath: resolvedPath,
          version: version
        )
      }
      for command in uniqueCommands where results[command] == nil {
        results[command] = UserShellCommandDetails(exists: false, resolvedPath: nil, version: nil)
      }
      return results
    } catch {
      return Dictionary(
        uniqueKeysWithValues: uniqueCommands.map {
          ($0, UserShellCommandDetails(exists: false, resolvedPath: nil, version: nil))
        })
    }
  }

  private static func interactivePath(
    environment: [String: String]
  ) -> String? {
    let shell = resolvedPath(environment: environment)
    let cacheKey = InteractivePathCacheKey(
      shell: shell,
      home: environment["HOME"],
      path: environment["PATH"],
      zdotdir: environment["ZDOTDIR"]
    )

    interactivePathCacheLock.lock()
    let cachedPath = interactivePathCache[cacheKey]
    interactivePathCacheLock.unlock()
    if let cachedPath {
      return cachedPath
    }

    let marker = "__ARGON_SHELL_PATH_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
    let script = """
      printf '%s\\n' '\(marker)'
      printf '%s\\n' "$PATH"
      printf '%s\\n' '\(marker)'
      """

    let process = Process()
    let processLaunch = launchSpec(command: script, environment: environment)
    process.executableURL = URL(fileURLWithPath: processLaunch.executable)
    process.arguments = processLaunch.args
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
      semaphore.signal()
    }

    do {
      try process.run()
    } catch {
      return nil
    }

    guard semaphore.wait(timeout: .now() + interactivePathProbeTimeout) == .success else {
      process.terminationHandler = nil
      process.terminate()
      return nil
    }
    process.terminationHandler = nil
    guard process.terminationStatus == 0 else {
      return nil
    }

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    guard let path = parseInteractivePathProbeOutput(output, marker: marker) else {
      return nil
    }

    interactivePathCacheLock.lock()
    interactivePathCache[cacheKey] = path
    interactivePathCacheLock.unlock()
    return path
  }

  private static func parseInteractivePathProbeOutput(
    _ output: String,
    marker: String
  ) -> String? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(of: marker) else { return nil }

    for index in lines.indices where index > start && lines[index] == marker {
      guard index == start + 2 else { return nil }
      let path = lines[start + 1].trimmingCharacters(in: .whitespacesAndNewlines)
      return path.isEmpty ? nil : path
    }

    return nil
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
