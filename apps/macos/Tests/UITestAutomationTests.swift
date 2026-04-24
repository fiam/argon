import XCTest

@testable import Argon

final class UITestAutomationTests: XCTestCase {
  func testCurrentReturnsEmptyConfigWhenNoEnvironmentKeysExist() {
    XCTAssertEqual(
      UITestAutomationConfig.current(environment: [:]),
      UITestAutomationConfig(
        reviewerLaunch: nil,
        reviewerExtraLaunches: [],
        signalFilePath: nil,
        websiteDemoEnabled: false,
        websiteDemoUsesLiveAgentCommands: false
      )
    )
  }

  func testCurrentParsesReviewerLaunchConfiguration() {
    let environment = [
      UITestAutomationConfig.reviewerCommandEnvironmentKey: "  /bin/sh -lc 'sleep 5'  ",
      UITestAutomationConfig.reviewerFocusEnvironmentKey: "  verify ghostty startup  ",
      UITestAutomationConfig.reviewerSandboxEnvironmentKey: "YES",
      UITestAutomationConfig.signalFileEnvironmentKey: "/tmp/argon-ui-signal",
    ]

    XCTAssertEqual(
      UITestAutomationConfig.current(environment: environment),
      UITestAutomationConfig(
        reviewerLaunch: .init(
          command: "/bin/sh -lc 'sleep 5'",
          focusPrompt: "verify ghostty startup",
          sandboxEnabled: true
        ),
        reviewerExtraLaunches: [],
        signalFilePath: "/tmp/argon-ui-signal",
        websiteDemoEnabled: false,
        websiteDemoUsesLiveAgentCommands: false
      )
    )
  }

  func testCurrentParsesMultipleReviewerLaunchesConfiguration() throws {
    let launches = [
      UITestAutomationConfig.ReviewerLaunch(
        name: "Codex",
        command: "codex",
        focusPrompt: "review merge-back safety",
        sandboxEnabled: true,
        icon: "codex"
      ),
      UITestAutomationConfig.ReviewerLaunch(
        name: "Gemini",
        command: "gemini",
        focusPrompt: "review website copy",
        sandboxEnabled: true,
        icon: "gemini"
      ),
    ]
    let data = try JSONEncoder().encode(launches)
    let environment = [
      UITestAutomationConfig.reviewersEnvironmentKey: String(
        decoding: data,
        as: UTF8.self
      ),
      UITestAutomationConfig.signalFileEnvironmentKey: "/tmp/argon-ui-signal",
    ]

    let config = UITestAutomationConfig.current(environment: environment)
    XCTAssertEqual(config.reviewerLaunches, launches)
    XCTAssertEqual(config.signalFilePath, "/tmp/argon-ui-signal")
  }

  func testCurrentIgnoresWhitespaceOnlyCommand() {
    let environment = [
      UITestAutomationConfig.reviewerCommandEnvironmentKey: "   "
    ]

    XCTAssertEqual(
      UITestAutomationConfig.current(environment: environment),
      UITestAutomationConfig(
        reviewerLaunch: nil,
        reviewerExtraLaunches: [],
        signalFilePath: nil,
        websiteDemoEnabled: false,
        websiteDemoUsesLiveAgentCommands: false
      )
    )
  }

  func testSignalWritesAppendEvents() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let path = tempDirectory.appendingPathComponent("signal.txt").path
    UITestAutomationSignal.write("first", to: path)
    UITestAutomationSignal.write("second", to: path)

    let contents = try String(contentsOfFile: path, encoding: .utf8)
    XCTAssertEqual(contents, "first\nsecond\n")
  }
}
