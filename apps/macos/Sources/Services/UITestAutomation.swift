import Foundation

struct UITestAutomationConfig: Equatable, Sendable {
  struct ReviewerLaunch: Equatable, Sendable, Codable {
    let name: String?
    let command: String
    let focusPrompt: String?
    let sandboxEnabled: Bool
    let icon: String?

    init(
      name: String? = nil,
      command: String,
      focusPrompt: String? = nil,
      sandboxEnabled: Bool,
      icon: String? = nil
    ) {
      self.name = name
      self.command = command
      self.focusPrompt = focusPrompt
      self.sandboxEnabled = sandboxEnabled
      self.icon = icon
    }
  }

  static let reviewerCommandEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWER_COMMAND"
  static let reviewersEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWERS"
  static let reviewerFocusEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWER_FOCUS"
  static let reviewerSandboxEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWER_SANDBOXED"
  static let signalFileEnvironmentKey = "ARGON_UI_TEST_SIGNAL_FILE"
  static let websiteDemoEnvironmentKey = "ARGON_UI_TEST_WEBSITE_DEMO"
  static let websiteDemoLiveAgentsEnvironmentKey = "ARGON_UI_TEST_WEBSITE_DEMO_LIVE_AGENTS"

  let reviewerLaunch: ReviewerLaunch?
  let reviewerExtraLaunches: [ReviewerLaunch]
  let signalFilePath: String?
  let websiteDemoEnabled: Bool
  let websiteDemoUsesLiveAgentCommands: Bool

  var reviewerLaunches: [ReviewerLaunch] {
    var launches: [ReviewerLaunch] = []
    if let reviewerLaunch {
      launches.append(reviewerLaunch)
    }
    launches.append(contentsOf: reviewerExtraLaunches)
    return launches
  }

  static func current(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let signalFilePath = environment[signalFileEnvironmentKey]
    let websiteDemoEnabled = parseBool(environment[websiteDemoEnvironmentKey])
    let websiteDemoUsesLiveAgentCommands = parseBool(
      environment[websiteDemoLiveAgentsEnvironmentKey]
    )

    if let rawReviewerLaunches = environment[reviewersEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawReviewerLaunches.isEmpty,
      let data = rawReviewerLaunches.data(using: .utf8),
      let launches = try? JSONDecoder().decode([ReviewerLaunch].self, from: data),
      let firstLaunch = launches.first
    {
      return Self(
        reviewerLaunch: firstLaunch,
        reviewerExtraLaunches: Array(launches.dropFirst()),
        signalFilePath: signalFilePath,
        websiteDemoEnabled: websiteDemoEnabled,
        websiteDemoUsesLiveAgentCommands: websiteDemoUsesLiveAgentCommands
      )
    }

    guard
      let command = environment[reviewerCommandEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !command.isEmpty
    else {
      return Self(
        reviewerLaunch: nil,
        reviewerExtraLaunches: [],
        signalFilePath: signalFilePath,
        websiteDemoEnabled: websiteDemoEnabled,
        websiteDemoUsesLiveAgentCommands: websiteDemoUsesLiveAgentCommands
      )
    }

    let focusPrompt = environment[reviewerFocusEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let sandboxEnabled = parseBool(environment[reviewerSandboxEnvironmentKey])

    return Self(
      reviewerLaunch: ReviewerLaunch(
        command: command,
        focusPrompt: focusPrompt?.isEmpty == false ? focusPrompt : nil,
        sandboxEnabled: sandboxEnabled
      ),
      reviewerExtraLaunches: [],
      signalFilePath: signalFilePath,
      websiteDemoEnabled: websiteDemoEnabled,
      websiteDemoUsesLiveAgentCommands: websiteDemoUsesLiveAgentCommands
    )
  }

  private static func parseBool(_ value: String?) -> Bool {
    guard let value else { return false }
    return switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
      true
    default:
      false
    }
  }
}

enum UITestAutomationSignal {
  static func write(_ value: String, to path: String?) {
    guard let path, !path.isEmpty else { return }
    let line = "\(value)\n"

    if FileManager.default.fileExists(atPath: path) {
      guard let handle = FileHandle(forWritingAtPath: path) else { return }
      do {
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
      } catch {
        try? handle.close()
      }
      return
    }

    try? line.write(toFile: path, atomically: true, encoding: .utf8)
  }
}
