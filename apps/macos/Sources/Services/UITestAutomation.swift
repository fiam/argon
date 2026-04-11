import Foundation

struct UITestAutomationConfig: Equatable, Sendable {
  struct ReviewerLaunch: Equatable, Sendable {
    let command: String
    let focusPrompt: String?
    let sandboxEnabled: Bool
  }

  static let reviewerCommandEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWER_COMMAND"
  static let reviewerFocusEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWER_FOCUS"
  static let reviewerSandboxEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWER_SANDBOXED"
  static let signalFileEnvironmentKey = "ARGON_UI_TEST_SIGNAL_FILE"

  let reviewerLaunch: ReviewerLaunch?
  let signalFilePath: String?

  static func current(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    guard
      let command = environment[reviewerCommandEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !command.isEmpty
    else {
      return Self(
        reviewerLaunch: nil,
        signalFilePath: environment[signalFileEnvironmentKey]
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
      signalFilePath: environment[signalFileEnvironmentKey]
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
