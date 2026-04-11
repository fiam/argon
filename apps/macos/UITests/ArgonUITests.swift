import Foundation
import XCTest

final class ArgonUITests: XCTestCase {
  private static let autoReviewerCommandEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWER_COMMAND"
  private static let signalFileEnvironmentKey = "ARGON_UI_TEST_SIGNAL_FILE"
  private static let disableStateRestorationArguments = [
    "-ApplePersistenceIgnoreState", "YES",
  ]
  private static let ghosttyCrashDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/ghostty/crash", isDirectory: true)

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testGhosttyCustomReviewerLaunchDoesNotCrash() throws {
    try runReviewerLaunchSmoke(
      command: "/bin/sh -lc 'printf started\\n; yes line | head -n 200; sleep 1'",
      expectedHostSignal: "ghostty-terminal-host-created"
    )
  }

  @MainActor
  func testGhosttyClaudeReviewerLaunchDoesNotCrash() throws {
    try requireCommandInstalled("claude")
    try runReviewerLaunchSmoke(
      command: "claude",
      expectedHostSignal: "ghostty-terminal-host-created"
    )
  }

  @MainActor
  func testGhosttyClaudeReviewerKeepsHeaderInteractive() throws {
    try requireCommandInstalled("claude")

    let target = try Self.createSession()
    let app = XCUIApplication()
    let signalFile = URL(fileURLWithPath: target.argonHome).appendingPathComponent("signal.txt")
    let crashSnapshot = Self.ghosttyCrashSnapshot()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.argonHome)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
      "--session-id", target.sessionId,
      "--repo-root", target.repoRoot,
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launchEnvironment[Self.autoReviewerCommandEnvironmentKey] = "claude"
    app.launchEnvironment[Self.signalFileEnvironmentKey] = signalFile.path
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(waitForSignal("reviewer-launched", at: signalFile, timeout: 20))
    XCTAssertTrue(waitForSignal("ghostty-terminal-host-created", at: signalFile, timeout: 10))
    XCTAssertTrue(waitForSignal("reviewer-tabs-appeared", at: signalFile, timeout: 10))
    sleep(8)

    let copyButton = app.buttons["Copy Agent Command"]
    XCTAssertTrue(copyButton.waitForExistence(timeout: 10))
    copyButton.tap()
    XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3))

    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertEqual(
      Self.ghosttyCrashSnapshot(),
      crashSnapshot,
      "Ghostty crash reports changed during the reviewer header interaction smoke test"
    )
  }

  @MainActor
  func testGhosttyClaudeReviewerKeepsHeaderInteractiveAfterTerminalClick() throws {
    try requireCommandInstalled("claude")

    let target = try Self.createSession()
    let app = XCUIApplication()
    let signalFile = URL(fileURLWithPath: target.argonHome).appendingPathComponent("signal.txt")
    let crashSnapshot = Self.ghosttyCrashSnapshot()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.argonHome)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
      "--session-id", target.sessionId,
      "--repo-root", target.repoRoot,
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launchEnvironment[Self.autoReviewerCommandEnvironmentKey] = "claude"
    app.launchEnvironment[Self.signalFileEnvironmentKey] = signalFile.path
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(waitForSignal("reviewer-launched", at: signalFile, timeout: 20))
    XCTAssertTrue(waitForSignal("ghostty-terminal-host-created", at: signalFile, timeout: 10))
    XCTAssertTrue(waitForSignal("reviewer-tabs-appeared", at: signalFile, timeout: 10))
    sleep(8)

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.78)).click()

    let copyButton = app.buttons["Copy Agent Command"]
    XCTAssertTrue(copyButton.waitForExistence(timeout: 10))
    copyButton.tap()
    XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3))

    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertEqual(
      Self.ghosttyCrashSnapshot(),
      crashSnapshot,
      "Ghostty crash reports changed during the terminal-click interaction smoke test"
    )
  }

  @MainActor
  func testGhosttyGeminiReviewerLaunchDoesNotCrash() throws {
    try requireCommandInstalled("gemini")
    try runReviewerLaunchSmoke(
      command: "gemini",
      expectedHostSignal: "ghostty-terminal-host-created"
    )
  }

  @MainActor
  func testGhosttyCodexReviewerLaunchDoesNotCrash() throws {
    try requireCommandInstalled("codex")
    try runReviewerLaunchSmoke(
      command: "codex",
      expectedHostSignal: "ghostty-terminal-host-created"
    )
  }

  private struct ReviewTarget {
    let sessionId: String
    let repoRoot: String
    let argonHome: String
  }

  private static func createSession() throws -> ReviewTarget {
    let repoRoot = repositoryRoot()
    let sessionId = UUID().uuidString.lowercased()
    let argonHome = temporaryArgonHome(sessionId: sessionId)
    let sessionsDirectory = sessionsDirectory(argonHome: argonHome, repoRoot: repoRoot)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: sessionsDirectory),
      withIntermediateDirectories: true
    )

    let timestamp = iso8601Timestamp()
    let sessionPayload: [String: Any] = [
      "id": sessionId,
      "repo_root": repoRoot,
      "mode": "uncommitted",
      "base_ref": "HEAD",
      "head_ref": "WORKTREE",
      "merge_base_sha": "HEAD",
      "change_summary": NSNull(),
      "status": "awaiting_reviewer",
      "threads": [],
      "decision": NSNull(),
      "agent_last_seen_at": NSNull(),
      "created_at": timestamp,
      "updated_at": timestamp,
    ]

    let sessionFile = URL(fileURLWithPath: sessionsDirectory).appendingPathComponent(
      "\(sessionId).json")
    let data = try JSONSerialization.data(withJSONObject: sessionPayload, options: [.prettyPrinted])
    try data.write(to: sessionFile, options: .atomic)

    return ReviewTarget(sessionId: sessionId, repoRoot: repoRoot, argonHome: argonHome)
  }

  private static func repositoryRoot(filePath: StaticString = #filePath) -> String {
    var url = URL(fileURLWithPath: "\(filePath)")
    for _ in 0..<4 {
      url.deleteLastPathComponent()
    }
    return url.path
  }

  private static func temporaryArgonHome(sessionId: String) -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-ui-tests", isDirectory: true)
      .appendingPathComponent(sessionId, isDirectory: true)
    return url.path
  }

  private static func sessionsDirectory(argonHome: String, repoRoot: String) -> String {
    URL(fileURLWithPath: argonHome)
      .appendingPathComponent("sessions")
      .appendingPathComponent(repoStorageKey(repoRoot: repoRoot))
      .path
  }

  private static func repoStorageKey(repoRoot: String) -> String {
    let resolved = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
    let name = URL(fileURLWithPath: resolved).lastPathComponent
    let sanitized = sanitizeRepoName(name)
    let repoName = sanitized.isEmpty ? "repo" : sanitized
    let hash = fnv1a64(Array(resolved.utf8))
    return "\(repoName)-\(String(format: "%016llx", hash))"
  }

  private static func sanitizeRepoName(_ name: String) -> String {
    String(
      name.compactMap { character -> Character? in
        let lower = character.lowercased().first!
        if lower.isASCII && (lower.isLetter || lower.isNumber || lower == "-" || lower == "_") {
          return lower
        }
        return nil
      })
  }

  private static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return hash
  }

  private static func iso8601Timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }

  private static func ghosttyCrashSnapshot() -> [String] {
    guard
      let contents = try? FileManager.default.contentsOfDirectory(
        atPath: ghosttyCrashDirectory.path)
    else {
      return []
    }

    return
      contents
      .filter { $0.hasSuffix(".ghosttycrash") }
      .sorted()
  }

  @MainActor
  private func runReviewerLaunchSmoke(
    command: String,
    expectedHostSignal: String
  ) throws {
    let target = try Self.createSession()
    let app = XCUIApplication()
    let signalFile = URL(fileURLWithPath: target.argonHome).appendingPathComponent("signal.txt")
    let crashSnapshot = Self.ghosttyCrashSnapshot()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.argonHome)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
      "--session-id", target.sessionId,
      "--repo-root", target.repoRoot,
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launchEnvironment[Self.autoReviewerCommandEnvironmentKey] = command
    app.launchEnvironment[Self.signalFileEnvironmentKey] = signalFile.path
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(waitForSignal("reviewer-launched", at: signalFile, timeout: 20))
    XCTAssertTrue(waitForSignal(expectedHostSignal, at: signalFile, timeout: 10))
    XCTAssertTrue(waitForSignal("reviewer-tabs-appeared", at: signalFile, timeout: 10))
    sleep(8)
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertEqual(
      Self.ghosttyCrashSnapshot(),
      crashSnapshot,
      "Ghostty crash reports changed during the reviewer launch smoke test"
    )
  }

  private func requireCommandInstalled(_ command: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bash", "-lc", "command -v -- \(shellQuote(command)) >/dev/null"]
    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      throw XCTSkip("Command not installed: \(command)")
    }
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func waitForSignal(_ expected: String, at url: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let contents = try? String(contentsOf: url, encoding: .utf8),
        contents
          .split(whereSeparator: \.isNewline)
          .contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == expected })
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }
}
