import Foundation

enum ArgonCLI {

  // MARK: - Highlighted Diff

  /// Runs `argon diff --session <id> --theme <theme> --json` and returns the raw JSON string.
  static func highlightedDiff(
    sessionId: String, repoRoot: String, theme: String
  ) throws -> String {
    try run(
      repoRoot: repoRoot,
      args: [
        "diff",
        "--session", sessionId,
        "--theme", theme,
        "--json",
      ])
  }

  // MARK: - Draft Comments

  static func addDraftComment(
    sessionId: String, repoRoot: String, message: String,
    filePath: String? = nil, lineNew: UInt32? = nil, lineOld: UInt32? = nil,
    threadId: String? = nil
  ) throws {
    var args = [
      "draft", "add",
      "--session", sessionId,
      "--message", message,
      "--json",
    ]
    if let threadId {
      args.append(contentsOf: ["--thread", threadId])
    }
    if let filePath {
      args.append(contentsOf: ["--file", filePath])
    }
    if let lineNew {
      args.append(contentsOf: ["--line-new", String(lineNew)])
    }
    if let lineOld {
      args.append(contentsOf: ["--line-old", String(lineOld)])
    }
    try run(repoRoot: repoRoot, args: args)
  }

  static func deleteDraftComment(
    sessionId: String, repoRoot: String, draftId: String
  ) throws {
    try run(
      repoRoot: repoRoot,
      args: [
        "draft", "delete",
        "--session", sessionId,
        "--draft-id", draftId,
        "--json",
      ])
  }

  static func submitReview(
    sessionId: String, repoRoot: String, outcome: String?, summary: String?
  ) throws {
    var args = [
      "draft", "submit",
      "--session", sessionId,
      "--json",
    ]
    if let outcome {
      args.append(contentsOf: ["--outcome", outcome])
    }
    if let summary {
      args.append(contentsOf: ["--summary", summary])
    }
    try run(repoRoot: repoRoot, args: args)
  }

  static func updateSessionTarget(
    sessionId: String, repoRoot: String,
    mode: String, baseRef: String, headRef: String, mergeBaseSha: String
  ) throws {
    try run(
      repoRoot: repoRoot,
      args: [
        "agent", "dev", "update-target",
        "--session", sessionId,
        "--mode", mode,
        "--base-ref", baseRef,
        "--head-ref", headRef,
        "--merge-base-sha", mergeBaseSha,
        "--json",
      ])
  }

  static func setDecision(
    sessionId: String, repoRoot: String, outcome: String, summary: String?
  ) throws {
    var args = [
      "agent", "dev", "decide",
      "--session", sessionId,
      "--outcome", outcome,
      "--json",
    ]
    if let summary {
      args.append(contentsOf: ["--summary", summary])
    }
    try run(repoRoot: repoRoot, args: args)
  }

  static func addComment(
    sessionId: String, repoRoot: String, message: String,
    filePath: String? = nil, lineNew: UInt32? = nil, lineOld: UInt32? = nil,
    threadId: String? = nil
  ) throws {
    var args = [
      "agent", "dev", "comment",
      "--session", sessionId,
      "--message", message,
      "--json",
    ]
    if let threadId {
      args.append(contentsOf: ["--thread", threadId])
    }
    if let filePath {
      args.append(contentsOf: ["--file", filePath])
    }
    if let lineNew {
      args.append(contentsOf: ["--line-new", String(lineNew)])
    }
    if let lineOld {
      args.append(contentsOf: ["--line-old", String(lineOld)])
    }
    try run(repoRoot: repoRoot, args: args)
  }

  static func resolveThread(sessionId: String, repoRoot: String, threadId: String) throws {
    try run(
      repoRoot: repoRoot,
      args: [
        "agent", "dev", "resolve-thread",
        "--session", sessionId,
        "--thread", threadId,
        "--json",
      ])
  }

  static func closeSession(sessionId: String, repoRoot: String) throws {
    try run(
      repoRoot: repoRoot,
      args: [
        "agent", "close",
        "--session", sessionId,
        "--json",
      ])
  }

  static func buildReviewerPrompt(
    sessionId: String, repoRoot: String, nickname: String,
    focusPrompt: String?, cli: String
  ) -> String {
    var lines: [String] = []
    lines.append(
      "You are reviewer \(nickname) for Argon session \(sessionId) in \(repoRoot)."
    )
    if let focus = focusPrompt, !focus.isEmpty {
      lines.append("Focus your review on: \(focus)")
    }
    lines.append("Review the current changes and leave feedback using these commands:")
    lines.append(
      "Comment: \(cli) --repo \(repoRoot) reviewer comment --session \(sessionId) --reviewer \(nickname) --message \"<comment>\" [--file <path> --line-new <n>]"
    )
    lines.append(
      "Decision: \(cli) --repo \(repoRoot) reviewer decide --session \(sessionId) --reviewer \(nickname) --outcome <changes-requested|commented>"
    )
    lines.append(
      "Wait for replies: \(cli) --repo \(repoRoot) reviewer wait --session \(sessionId) --reviewer \(nickname) --json"
    )
    lines.append("Do NOT approve — only the human reviewer can approve.")
    lines.append("Do NOT edit files. You may inspect the repo and run tests.")
    return lines.joined(separator: "\n")
  }

  @discardableResult
  private static func run(repoRoot: String, args: [String]) throws -> String {
    let cli = findCLI()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli)
    process.arguments = ["--repo", repoRoot] + args
    process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()

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

    if let bundlePath = Bundle.main.executableURL?
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/bin/argon").path,
      FileManager.default.fileExists(atPath: bundlePath)
    {
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
