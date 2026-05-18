import Foundation

enum ArgonCLI {
  struct SandboxConfigEntry: Decodable, Sendable {
    let directory: String
    let sandboxfilePath: String
    let dotSandboxfilePath: String
    let compatibilityPath: String
    let existingPath: String?
  }

  struct SandboxConfigPaths: Decodable, Sendable {
    let initPath: String?
    let entries: [SandboxConfigEntry]
    let existingPaths: [String]
  }

  struct SandboxInitResult: Decodable, Sendable {
    let path: String
    let created: Bool
  }

  struct SandboxExplainResponse: Decodable, Sendable {
    let policy: SandboxExplainPolicy
  }

  struct SandboxExplainPolicy: Decodable, Equatable, Sendable {
    let netDefault: SandboxNetDefault
    let proxiedHosts: [String]
    let connectRules: [SandboxConnectRule]
  }

  enum SandboxNetDefault: String, Decodable, Equatable, Sendable {
    case allow
    case none
  }

  struct SandboxConnectRule: Decodable, Equatable, Sendable {
    let `protocol`: String
    let target: String
  }

  // MARK: - CLI Discovery

  static func cliPath() -> String {
    findCLI()
  }

  static func bundledCLIPath() -> String? {
    let helperPath = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/argon").path
    if FileManager.default.fileExists(atPath: helperPath) {
      return helperPath
    }

    if let executablePath = Bundle.main.executableURL?
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Helpers/argon").path,
      FileManager.default.fileExists(atPath: executablePath)
    {
      return executablePath
    }

    if let resourcePath = Bundle.main.resourceURL?
      .appendingPathComponent("bin/argon").path,
      FileManager.default.fileExists(atPath: resourcePath)
    {
      return resourcePath
    }

    if let executablePath = Bundle.main.executableURL?
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/bin/argon").path,
      FileManager.default.fileExists(atPath: executablePath)
    {
      return executablePath
    }

    return nil
  }

  static func sandboxConfigPaths(repoRoot: String?) throws -> SandboxConfigPaths {
    let output = try run(repoRoot: repoRoot, args: ["sandbox", "config", "paths", "--json"])
    return try decode(SandboxConfigPaths.self, from: output)
  }

  static func sandboxInit(repoRoot: String) throws -> SandboxInitResult {
    let output = try run(
      repoRoot: repoRoot,
      args: ["sandbox", "init", "--repo-root", repoRoot, "--json"]
    )
    return try decode(SandboxInitResult.self, from: output)
  }

  static func sandboxExplain(
    repoRoot: String,
    sandboxExecArguments: [String]
  ) throws -> SandboxExplainResponse {
    let args = try sandboxExplainArguments(fromSandboxExecArguments: sandboxExecArguments)
    let output = try run(repoRoot: repoRoot, args: args)
    return try decode(SandboxExplainResponse.self, from: output)
  }

  static func sandboxExplainArguments(
    fromSandboxExecArguments sandboxExecArguments: [String]
  ) throws -> [String] {
    guard sandboxExecArguments.count >= 2,
      sandboxExecArguments[0] == "sandbox",
      sandboxExecArguments[1] == "exec"
    else {
      throw CLIError.commandFailed("Expected sandbox exec launch arguments")
    }

    let contextArguments = Array(
      sandboxExecArguments
        .dropFirst(2)
        .prefix { $0 != "--" }
    )
    return ["sandbox", "explain", "--json"] + contextArguments
  }

  @discardableResult
  private static func run(repoRoot: String?, args: [String], stdin: String? = nil) throws -> String
  {
    let cli = findCLI()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli)
    process.arguments = (repoRoot.map { ["--repo", $0] } ?? []) + args
    if let repoRoot {
      process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
    }

    let stdinPipe = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    if stdin != nil {
      process.standardInput = stdinPipe
    }
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()

    if let stdin {
      if let data = stdin.data(using: .utf8) {
        stdinPipe.fileHandleForWriting.write(data)
      }
      try? stdinPipe.fileHandleForWriting.close()
    }

    // Read pipes before waitUntilExit to avoid deadlock when
    // output exceeds the pipe buffer.
    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(data: outputData, encoding: .utf8) ?? ""

    if process.terminationStatus != 0 {
      let err = String(data: errorData, encoding: .utf8) ?? "unknown error"
      throw CLIError.commandFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return output
  }

  private static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let data = output.data(using: .utf8) else {
      throw CLIError.commandFailed("Failed to decode CLI output")
    }
    return try decoder.decode(type, from: data)
  }

  private static func findCLI() -> String {
    if let cli = ProcessInfo.processInfo.environment["ARGON_CLI_CMD"], !cli.isEmpty {
      let trimmed = cli.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
      if FileManager.default.fileExists(atPath: trimmed) {
        return trimmed
      }
    }

    if let cli = ProcessInfo.processInfo.environment["ARGON_CLI"], !cli.isEmpty {
      return cli
    }

    if let bundlePath = bundledCLIPath() {
      return bundlePath
    }

    for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
      let path = "\(dir)/argon"
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }

    return "/usr/local/bin/argon"
  }

  enum CLIError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
      switch self {
      case .commandFailed(let msg): msg
      }
    }
  }
}
