import Foundation

// MARK: - Agent Profiles

struct AgentProfile: Identifiable, Hashable {
  let id: String
  let name: String
  let command: String
  let icon: String
  let isDetected: Bool

  static func == (lhs: AgentProfile, rhs: AgentProfile) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// MARK: - Agent Detection

enum AgentDetector {
  static func detectAgents() -> [AgentProfile] {
    var agents: [AgentProfile] = []

    if commandExists("claude") {
      agents.append(
        AgentProfile(
          id: "claude-code",
          name: "Claude Code",
          command: "claude",
          icon: "brain",
          isDetected: true
        ))
      agents.append(
        AgentProfile(
          id: "claude-code-yolo",
          name: "Claude Code (YOLO)",
          command: "claude --dangerously-skip-permissions",
          icon: "brain.head.profile",
          isDetected: true
        ))
    }

    if commandExists("codex") {
      agents.append(
        AgentProfile(
          id: "codex",
          name: "Codex",
          command: "codex",
          icon: "terminal",
          isDetected: true
        ))
      agents.append(
        AgentProfile(
          id: "codex-yolo",
          name: "Codex (YOLO)",
          command: "codex --yolo",
          icon: "terminal.fill",
          isDetected: true
        ))
    }

    if commandExists("gemini") {
      agents.append(
        AgentProfile(
          id: "gemini",
          name: "Gemini CLI",
          command: "gemini",
          icon: "sparkles",
          isDetected: true
        ))
    }

    return agents
  }

  private static func commandExists(_ command: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [command]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}

// MARK: - Detective Names

@MainActor
enum DetectiveNames {
  private static let names = [
    "Sherlock", "Poirot", "Columbo", "Marple",
    "Morse", "Clouseau", "Monk", "Benoit Blanc",
    "Veronica Mars", "Pikachu", "Scooby",
    "Wallander", "Rebus", "Bosch", "Gamache",
    "Frost", "Barnaby", "Wexford", "Dalglish",
    "Luther", "Bones", "Castle", "Lisbeth",
  ]

  private static var usedNames: Set<String> = []

  static func next() -> String {
    let available = names.filter { !usedNames.contains($0) }
    let name = available.randomElement() ?? "Agent-\(Int.random(in: 100...999))"
    usedNames.insert(name)
    return name
  }

  static func release(_ name: String) {
    usedNames.remove(name)
  }
}

// MARK: - Running Reviewer Agent

@Observable
@MainActor
final class ReviewerAgentInstance: Identifiable {
  let id = UUID()
  let nickname: String
  let profile: AgentProfile
  let focusPrompt: String?
  let sessionId: String
  let repoRoot: String
  var isRunning = true
  var hasComments = false
  var lastDecision: String?  // "commented", "changes_requested", nil
  var process: Process?

  init(
    nickname: String, profile: AgentProfile, focusPrompt: String?,
    sessionId: String, repoRoot: String
  ) {
    self.nickname = nickname
    self.profile = profile
    self.focusPrompt = focusPrompt
    self.sessionId = sessionId
    self.repoRoot = repoRoot
  }

  /// The full command with the reviewer prompt appended.
  var fullCommand: String {
    let cli = ProcessInfo.processInfo.environment["ARGON_CLI_CMD"] ?? "argon"
    let prompt = ArgonCLI.buildReviewerPrompt(
      sessionId: sessionId, repoRoot: repoRoot,
      nickname: nickname, focusPrompt: focusPrompt, cli: cli
    )

    let baseCommand = profile.command
    // Append the prompt as an argument
    return "\(baseCommand) \(shellQuote(prompt))"
  }

  func stop() {
    process?.terminate()
    isRunning = false
    DetectiveNames.release(nickname)
  }

  private func shellQuote(_ s: String) -> String {
    "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}
