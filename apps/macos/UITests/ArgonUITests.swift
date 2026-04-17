import Foundation
import XCTest

final class ArgonUITests: XCTestCase {
  private static let autoReviewerCommandEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWER_COMMAND"
  private static let signalFileEnvironmentKey = "ARGON_UI_TEST_SIGNAL_FILE"
  private static let disableStateRestorationArguments = [
    "-ApplePersistenceIgnoreState", "YES",
  ]
  private static let gitExecutableCandidates = [
    "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    "/Library/Developer/CommandLineTools/usr/bin/git",
    "/usr/bin/git",
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

    let copyButton = app.buttons["CoderHandoffButton"]
    XCTAssertTrue(copyButton.waitForExistence(timeout: 10))
    copyButton.tap()
    XCTAssertTrue(app.otherElements["AgentPromptToast"].waitForExistence(timeout: 3))

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

    let copyButton = app.buttons["CoderHandoffButton"]
    XCTAssertTrue(copyButton.waitForExistence(timeout: 10))
    copyButton.tap()
    XCTAssertTrue(app.otherElements["AgentPromptToast"].waitForExistence(timeout: 3))

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

  @MainActor
  func testCoderHandoffLaunchHidesPromptSetupActions() throws {
    let target = try Self.createSession()
    let app = XCUIApplication()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.argonHome)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
      "--session-id", target.sessionId,
      "--repo-root", target.repoRoot,
      "--review-launch-context", "coderHandoff",
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

    let connectionBadge = app.otherElements["CoderConnectionBadge"]
    XCTAssertTrue(connectionBadge.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Connecting coder"].exists)
    XCTAssertFalse(app.buttons["CoderHandoffButton"].exists)
    XCTAssertTrue(app.buttons["launch-reviewer-button"].exists)
  }

  @MainActor
  func testWorkspaceSidebarShowsConflictMarkerForConflictedWorktree() throws {
    let target = try Self.createConflictedWorkspace()
    let app = XCUIApplication()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.fixtureRoot)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
      "--workspace-repo-root", target.repoRoot,
      "--workspace-common-dir", target.repoCommonDir,
      "--selected-worktree-path", target.selectedWorktreePath,
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace-sidebar-conflicts"].waitForExistence(timeout: 15)
    )
  }

  @MainActor
  func testWorkspaceReviewExternalLaunchOpensManualPasteState() throws {
    let target = try Self.createWorkspace()
    let app = XCUIApplication()
    let signalFile = URL(fileURLWithPath: target.argonHome).appendingPathComponent("signal.txt")
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.fixtureRoot)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
      "--workspace-repo-root", target.repoRoot,
      "--workspace-common-dir", target.repoCommonDir,
      "--selected-worktree-path", target.selectedWorktreePath,
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launchEnvironment[Self.signalFileEnvironmentKey] = signalFile.path
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

    let reviewButton = app.buttons["workspace-review-button"]
    XCTAssertTrue(reviewButton.waitForExistence(timeout: 10))
    reviewButton.tap()

    let externalButton = app.buttons["workspace-review-external-button"]
    XCTAssertTrue(externalButton.waitForExistence(timeout: 10))
    externalButton.tap()

    XCTAssertTrue(waitForSignal("review-window-appeared", at: signalFile, timeout: 10))
    XCTAssertTrue(waitForSignal("session-loaded", at: signalFile, timeout: 10))
    XCTAssertTrue(app.staticTexts["Paste into agent"].waitForExistence(timeout: 10))
    let copyAgainButton = app.buttons.matching(
      NSPredicate(format: "label == %@", "Copy Prompt Again")
    ).firstMatch
    XCTAssertTrue(copyAgainButton.waitForExistence(timeout: 10))
    XCTAssertEqual(copyAgainButton.label, "Copy Prompt Again")

    let copiedPrompt = NSPasteboard.general.string(forType: .string) ?? ""
    XCTAssertTrue(copiedPrompt.hasPrefix("You are reviewing feedback for Argon session"))
    XCTAssertTrue(copiedPrompt.contains("Execution contract:"))
    XCTAssertTrue(copiedPrompt.contains("agent wait"))
    XCTAssertFalse(copiedPrompt.contains("session: "))
    XCTAssertFalse(copiedPrompt.contains("agent-prompt-command:"))
  }

  @MainActor
  func testSubmitReviewSheetAcceptsCommandReturn() throws {
    let target = try Self.createSession()
    let app = XCUIApplication()
    let signalFile = URL(fileURLWithPath: target.argonHome).appendingPathComponent("signal.txt")
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
    app.launchEnvironment[Self.signalFileEnvironmentKey] = signalFile.path
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(waitForSignal("load-session-started", at: signalFile, timeout: 10))
    XCTAssertTrue(waitForSignal("session-loaded", at: signalFile, timeout: 20))
    app.activate()

    let submitButton = app.buttons.matching(NSPredicate(format: "label == %@", "Submit Review"))
      .firstMatch
    XCTAssertTrue(submitButton.waitForExistence(timeout: 20))
    submitButton.click()

    let submitSummaryEditor = app.descendants(matching: .any)["submit-review-summary-editor"]
    XCTAssertTrue(submitSummaryEditor.waitForExistence(timeout: 10))
    submitSummaryEditor.click()

    app.typeKey(.return, modifierFlags: .command)

    XCTAssertTrue(waitForNonExistence(submitSummaryEditor, timeout: 5))
    XCTAssertTrue(app.staticTexts["Approved"].waitForExistence(timeout: 5))
  }

  private struct ReviewTarget {
    let sessionId: String
    let repoRoot: String
    let argonHome: String
  }

  private struct WorkspaceLaunchTarget {
    let fixtureRoot: String
    let repoRoot: String
    let repoCommonDir: String
    let selectedWorktreePath: String
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

  private static func createConflictedWorkspace() throws -> WorkspaceLaunchTarget {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-ui-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repoRoot = fixtureRoot.appendingPathComponent("repo", isDirectory: true)
    let worktreeRoot =
      fixtureRoot
      .appendingPathComponent("worktrees", isDirectory: true)
      .appendingPathComponent("feature-conflicted", isDirectory: true)
    let argonHome = fixtureRoot.appendingPathComponent("argon-home", isDirectory: true)

    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: worktreeRoot.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: argonHome, withIntermediateDirectories: true)

    try git(repoRoot, ["init"])
    try git(repoRoot, ["config", "user.name", "Argon UI Test"])
    try git(repoRoot, ["config", "user.email", "argon-ui-test@example.com"])

    let conflictFile = "conflict.txt"
    try "shared line\n".write(
      to: repoRoot.appendingPathComponent(conflictFile),
      atomically: true,
      encoding: .utf8
    )
    try git(repoRoot, ["add", conflictFile])
    try git(repoRoot, ["commit", "-m", "Initial commit"])
    try git(repoRoot, ["branch", "-M", "main"])

    try git(repoRoot, ["worktree", "add", "-b", "feature/conflicted", worktreeRoot.path, "HEAD"])

    try "main branch change\n".write(
      to: repoRoot.appendingPathComponent(conflictFile),
      atomically: true,
      encoding: .utf8
    )
    try git(repoRoot, ["commit", "-am", "Main branch change"])

    try "feature branch change\n".write(
      to: worktreeRoot.appendingPathComponent(conflictFile),
      atomically: true,
      encoding: .utf8
    )
    try git(worktreeRoot, ["commit", "-am", "Feature branch change"])
    _ = try git(worktreeRoot, ["merge", "main"], allowFailure: true)

    return WorkspaceLaunchTarget(
      fixtureRoot: fixtureRoot.path,
      repoRoot: repoRoot.path,
      repoCommonDir: repoRoot.appendingPathComponent(".git", isDirectory: true).path,
      selectedWorktreePath: worktreeRoot.path,
      argonHome: argonHome.path
    )
  }

  private static func createWorkspace() throws -> WorkspaceLaunchTarget {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-ui-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repoRoot = fixtureRoot.appendingPathComponent("repo", isDirectory: true)
    let argonHome = fixtureRoot.appendingPathComponent("argon-home", isDirectory: true)

    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: argonHome, withIntermediateDirectories: true)

    try git(repoRoot, ["init"])
    try git(repoRoot, ["config", "user.name", "Argon UI Test"])
    try git(repoRoot, ["config", "user.email", "argon-ui-test@example.com"])

    try "initial\n".write(
      to: repoRoot.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(repoRoot, ["add", "README.md"])
    try git(repoRoot, ["commit", "-m", "Initial commit"])
    try git(repoRoot, ["branch", "-M", "main"])

    return WorkspaceLaunchTarget(
      fixtureRoot: fixtureRoot.path,
      repoRoot: repoRoot.path,
      repoCommonDir: repoRoot.appendingPathComponent(".git", isDirectory: true).path,
      selectedWorktreePath: repoRoot.path,
      argonHome: argonHome.path
    )
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

  private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  @discardableResult
  private static func git(
    _ workingDirectory: URL, _ arguments: [String], allowFailure: Bool = false
  )
    throws -> String
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gitExecutablePath())
    process.currentDirectoryURL = workingDirectory
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output =
      String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
      ?? ""
    let errorOutput =
      String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""

    if process.terminationStatus != 0 && !allowFailure {
      throw NSError(
        domain: "ArgonUITests.git",
        code: Int(process.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey:
            "git \(arguments.joined(separator: " ")) failed: \(errorOutput)"
        ]
      )
    }

    return output
  }

  private static func gitExecutablePath() -> String {
    for candidate in gitExecutableCandidates
    where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }

    return "/usr/bin/git"
  }
}
