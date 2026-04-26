import Foundation
import XCTest

final class ArgonUITests: XCTestCase {
  private static let autoReviewerCommandEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWER_COMMAND"
  private static let autoReviewersEnvironmentKey = "ARGON_UI_TEST_AUTO_REVIEWERS"
  private static let signalFileEnvironmentKey = "ARGON_UI_TEST_SIGNAL_FILE"
  private static let workspaceSnapshotEnvironmentKey = "ARGON_UI_TEST_WORKSPACE_SNAPSHOT_FILE"
  private static let disableCLIInstallPromptEnvironmentKey =
    "ARGON_UI_TEST_DISABLE_CLI_INSTALL_PROMPT"
  private static let screenshotLiveAgentsConfigFileName =
    ".website-screenshot-live-agents"
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

  private static func workspaceSidebarAccessibilityIdentifier(for path: String) -> String {
    let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
      (partial ^ UInt64(byte)) &* 1_099_511_628_211
    }
    let lastComponent = URL(fileURLWithPath: path).lastPathComponent
    return "workspace-sidebar-row-\(lastComponent)-\(String(hash, radix: 16))"
  }

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
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(
      app.descendants(matching: .any)["workspace-sidebar-conflicts"].waitForExistence(timeout: 15)
    )
  }

  @MainActor
  func testLinkedWorktreeShowsFinalizeActions() throws {
    let target = try Self.createLinkedWorkspace()
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
    XCTAssertTrue(app.buttons["workspace-merge-back-button"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["workspace-merge-style-button"].exists)
    XCTAssertTrue(app.buttons["workspace-open-pr-button"].exists)
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
  func testCaptureWebsiteWorkspaceScreenshot() throws {
    let target = try Self.createWebsiteWorkspace()
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
    app.launchEnvironment[Self.signalFileEnvironmentKey] = target.signalFile
    app.launchEnvironment["ARGON_UI_TEST_WEBSITE_DEMO"] = "1"
    app.launchEnvironment[Self.disableCLIInstallPromptEnvironmentKey] = "1"
    if Self.websiteScreenshotUsesLiveAgents() {
      app.launchEnvironment["ARGON_UI_TEST_WEBSITE_DEMO_LIVE_AGENTS"] = "1"
    }
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(
      waitForSignal("website-demo-ready", at: URL(fileURLWithPath: target.signalFile), timeout: 20)
    )

    let selectedSidebarRow = app.descendants(matching: .any)[
      Self.workspaceSidebarAccessibilityIdentifier(for: target.selectedWorktreePath)
    ]
    XCTAssertTrue(selectedSidebarRow.waitForExistence(timeout: 15))
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    sleep(1)
    Self.attachScreenshot(window.screenshot(), named: "workspace-window")
  }

  @MainActor
  func testCaptureWebsiteFeatureWorktreesScreenshot() throws {
    let target = try Self.createWebsiteWorkspace()
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
    app.launchEnvironment[Self.signalFileEnvironmentKey] = target.signalFile
    app.launchEnvironment["ARGON_UI_TEST_WEBSITE_DEMO"] = "1"
    app.launchEnvironment[Self.disableCLIInstallPromptEnvironmentKey] = "1"
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(
      waitForSignal("website-demo-ready", at: URL(fileURLWithPath: target.signalFile), timeout: 20)
    )

    let row = app.descendants(matching: .any)[
      Self.workspaceSidebarAccessibilityIdentifier(for: target.connectorsWorktreePath)
    ]
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    row.click()
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    sleep(1)
    Self.attachScreenshot(window.screenshot(), named: "feature-worktrees")
  }

  @MainActor
  func testCaptureWebsiteFeatureTerminalsScreenshot() throws {
    let target = try Self.createWebsiteWorkspace()
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
    app.launchEnvironment[Self.signalFileEnvironmentKey] = target.signalFile
    app.launchEnvironment["ARGON_UI_TEST_WEBSITE_DEMO"] = "1"
    app.launchEnvironment[Self.disableCLIInstallPromptEnvironmentKey] = "1"
    if Self.websiteScreenshotUsesLiveAgents() {
      app.launchEnvironment["ARGON_UI_TEST_WEBSITE_DEMO_LIVE_AGENTS"] = "1"
    }
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(
      waitForSignal("website-demo-ready", at: URL(fileURLWithPath: target.signalFile), timeout: 20)
    )

    let codexTab = app.buttons["workspace-terminal-tab-codex"]
    XCTAssertTrue(codexTab.waitForExistence(timeout: 15))
    codexTab.click()
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    sleep(1)
    Self.attachScreenshot(window.screenshot(), named: "feature-terminals")
  }

  @MainActor
  func testCaptureWebsiteFeatureReviewScreenshot() throws {
    let target = try Self.createWebsiteReviewSession()
    let app = XCUIApplication()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.fixtureRoot)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
      "--session-id", target.sessionId,
      "--repo-root", target.repoRoot,
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launchEnvironment[Self.signalFileEnvironmentKey] = target.signalFile
    app.launchEnvironment[Self.disableCLIInstallPromptEnvironmentKey] = "1"
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(
      waitForSignal(
        "review-window-appeared", at: URL(fileURLWithPath: target.signalFile), timeout: 20)
    )
    XCTAssertTrue(
      waitForSignal("session-loaded", at: URL(fileURLWithPath: target.signalFile), timeout: 20)
    )

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    sleep(2)
    Self.attachScreenshot(window.screenshot(), named: "feature-review")
  }

  @MainActor
  func testCaptureWebsiteReviewScreenshot() throws {
    let target = try Self.createWebsiteReviewSession()
    let app = XCUIApplication()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.fixtureRoot)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
      "--session-id", target.sessionId,
      "--repo-root", target.repoRoot,
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launchEnvironment[Self.signalFileEnvironmentKey] = target.signalFile
    app.launchEnvironment[Self.disableCLIInstallPromptEnvironmentKey] = "1"
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(
      waitForSignal(
        "review-window-appeared", at: URL(fileURLWithPath: target.signalFile), timeout: 20)
    )
    XCTAssertTrue(
      waitForSignal("session-loaded", at: URL(fileURLWithPath: target.signalFile), timeout: 20)
    )

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))

    sleep(2)

    Self.attachScreenshot(window.screenshot(), named: "review-window")
  }

  @MainActor
  func testCaptureWebsiteReviewAgentsScreenshot() throws {
    let target = try Self.createWebsiteReviewSession()
    let app = XCUIApplication()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.fixtureRoot)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
      "--session-id", target.sessionId,
      "--repo-root", target.repoRoot,
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launchEnvironment[Self.signalFileEnvironmentKey] = target.signalFile
    app.launchEnvironment[Self.disableCLIInstallPromptEnvironmentKey] = "1"
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(
      waitForSignal(
        "review-window-appeared", at: URL(fileURLWithPath: target.signalFile), timeout: 20)
    )
    XCTAssertTrue(
      waitForSignal("session-loaded", at: URL(fileURLWithPath: target.signalFile), timeout: 20)
    )
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    sleep(2)
    Self.attachScreenshot(window.screenshot(), named: "review-agents")
  }

  @MainActor
  func testWorkspaceRestoreLoadsTabsLazilyAndShowsToastForMissingAgents() throws {
    let target = try Self.createLazyRestoreWorkspace()
    let app = XCUIApplication()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(atPath: target.fixtureRoot)
    }

    app.launchArguments = [
      Self.disableStateRestorationArguments[0],
      Self.disableStateRestorationArguments[1],
    ]
    app.launchEnvironment["ARGON_HOME"] = target.argonHome
    app.launchEnvironment[Self.signalFileEnvironmentKey] = target.signalFile
    app.launchEnvironment[Self.workspaceSnapshotEnvironmentKey] = target.snapshotFile
    app.launch()

    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    XCTAssertTrue(
      waitForSignalCount(
        "ghostty-terminal-host-created",
        at: URL(fileURLWithPath: target.signalFile),
        expectedCount: 1,
        timeout: 20
      )
    )
    XCTAssertEqual(
      signalCount(
        "ghostty-terminal-host-created",
        at: URL(fileURLWithPath: target.signalFile)
      ),
      1
    )

    let featureRow = app.buttons[
      Self.workspaceSidebarAccessibilityIdentifier(for: target.featureWorktreePath)
    ]
    XCTAssertTrue(featureRow.waitForExistence(timeout: 10))
    featureRow.click()

    XCTAssertTrue(
      waitForSignalCount(
        "ghostty-terminal-host-created",
        at: URL(fileURLWithPath: target.signalFile),
        expectedCount: 2,
        timeout: 10
      )
    )
    XCTAssertTrue(
      waitForSignal(
        "workspace-restore-failure-toast-shown",
        at: URL(fileURLWithPath: target.signalFile),
        timeout: 5
      )
    )
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

  private struct RestoredWorkspaceLaunchTarget {
    let fixtureRoot: String
    let featureWorktreePath: String
    let argonHome: String
    let snapshotFile: String
    let signalFile: String
  }

  private struct WebsiteWorkspaceLaunchTarget {
    let fixtureRoot: String
    let repoRoot: String
    let repoCommonDir: String
    let selectedWorktreePath: String
    let reviewWorktreePath: String
    let sandboxWorktreePath: String
    let connectorsWorktreePath: String
    let argonHome: String
    let signalFile: String
  }

  private struct WebsiteReviewLaunchTarget {
    let fixtureRoot: String
    let sessionId: String
    let repoRoot: String
    let argonHome: String
    let signalFile: String
  }

  private static func writeGeneratedLines(
    to url: URL,
    header: [String] = [],
    footer: [String] = [],
    count: Int,
    makeLine: (Int) -> String
  ) throws {
    var lines = header
    lines.reserveCapacity(header.count + count + footer.count + 1)
    if count > 0 {
      for index in 1...count {
        lines.append(makeLine(index))
      }
    }
    lines.append(contentsOf: footer)
    lines.append("")
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  private static func nullable(_ value: Int?) -> Any {
    value.map { $0 as Any } ?? NSNull()
  }

  private static func nullable(_ value: String?) -> Any {
    value.map { $0 as Any } ?? NSNull()
  }

  private static func reviewThread(
    id: String,
    state: String,
    agentAcknowledgedAt: String? = nil,
    comments: [[String: Any]]
  ) -> [String: Any] {
    [
      "id": id,
      "state": state,
      "agent_acknowledged_at": nullable(agentAcknowledgedAt),
      "comments": comments,
    ]
  }

  private static func reviewComment(
    id: String,
    threadId: String,
    authorName: String,
    filePath: String,
    lineNew: Int? = nil,
    lineOld: Int? = nil,
    body: String,
    timestamp: String
  ) -> [String: Any] {
    [
      "id": id,
      "thread_id": threadId,
      "author": "reviewer",
      "author_name": authorName,
      "kind": "line",
      "anchor": [
        "file_path": filePath,
        "line_new": nullable(lineNew),
        "line_old": nullable(lineOld),
      ],
      "body": body,
      "created_at": timestamp,
    ]
  }

  private static func websiteReviewThreads(timestamp: String) -> [[String: Any]] {
    let sandboxThreadId = "11111111-1111-1111-1111-111111111111"
    let shellThreadId = "22222222-2222-2222-2222-222222222222"
    let manifestThreadId = "33333333-3333-3333-3333-333333333333"
    let legacyThreadId = "44444444-4444-4444-4444-444444444444"
    let telemetryThreadId = "55555555-5555-5555-5555-555555555555"

    return [
      reviewThread(
        id: sandboxThreadId,
        state: "open",
        comments: [
          reviewComment(
            id: "aaaaaaaa-1111-1111-1111-111111111111",
            threadId: sandboxThreadId,
            authorName: "Alex",
            filePath: "Sandboxfile",
            lineNew: 5,
            body: "Call out that proxy-backed traffic shows up live in the inspector.",
            timestamp: timestamp
          ),
          reviewComment(
            id: "aaaaaaaa-2222-2222-2222-222222222222",
            threadId: sandboxThreadId,
            authorName: "Codex",
            filePath: "Sandboxfile",
            lineNew: 5,
            body:
              "Gemini, keep the proxy-backed network story explicit so reviewer agents can validate it before merge-back.",
            timestamp: timestamp
          ),
          reviewComment(
            id: "aaaaaaaa-3333-3333-3333-333333333333",
            threadId: sandboxThreadId,
            authorName: "Gemini",
            filePath: "Sandboxfile",
            lineNew: 5,
            body:
              "Agreed. I will also call out that sandboxing is the default for integrated agent launches, not an opt-in afterthought.",
            timestamp: timestamp
          ),
        ]
      ),
      reviewThread(
        id: shellThreadId,
        state: "addressed",
        agentAcknowledgedAt: timestamp,
        comments: [
          reviewComment(
            id: "bbbbbbbb-1111-1111-1111-111111111111",
            threadId: shellThreadId,
            authorName: "Sam",
            filePath: "Sources/WorkspaceShell.swift",
            lineNew: 42,
            body: "Mention that coding, review, and merge-back stay in the same workspace.",
            timestamp: timestamp
          ),
          reviewComment(
            id: "bbbbbbbb-2222-2222-2222-222222222222",
            threadId: shellThreadId,
            authorName: "Codex",
            filePath: "Sources/WorkspaceShell.swift",
            lineNew: 115,
            body:
              "I added the repeated launch checkpoints so the screenshot shows the review loop at production scale.",
            timestamp: timestamp
          ),
        ]
      ),
      reviewThread(
        id: manifestThreadId,
        state: "open",
        comments: [
          reviewComment(
            id: "dddddddd-1111-1111-1111-111111111111",
            threadId: manifestThreadId,
            authorName: "Priya",
            filePath: "Sources/SandboxPolicyManifest.swift",
            lineNew: 240,
            body:
              "This manifest is the right place to make read and write boundaries inspectable before an agent runs.",
            timestamp: timestamp
          ),
          reviewComment(
            id: "dddddddd-2222-2222-2222-222222222222",
            threadId: manifestThreadId,
            authorName: "Gemini",
            filePath: "Sources/SandboxPolicyManifest.swift",
            lineNew: 612,
            body:
              "Please keep the generated policy rows grouped by permission type so reviewers can scan the large diff quickly.",
            timestamp: timestamp
          ),
          reviewComment(
            id: "dddddddd-3333-3333-3333-333333333333",
            threadId: manifestThreadId,
            authorName: "Codex",
            filePath: "Sources/SandboxPolicyManifest.swift",
            lineNew: 880,
            body:
              "The deny-write entries now mirror the sandbox summary, so the human reviewer can compare the code and runtime evidence.",
            timestamp: timestamp
          ),
        ]
      ),
      reviewThread(
        id: legacyThreadId,
        state: "open",
        comments: [
          reviewComment(
            id: "eeeeeeee-1111-1111-1111-111111111111",
            threadId: legacyThreadId,
            authorName: "Mina",
            filePath: "Sources/LegacySandboxPolicy.swift",
            lineOld: 170,
            body:
              "The deletion is good, but the release notes should say this legacy policy path has been removed.",
            timestamp: timestamp
          ),
          reviewComment(
            id: "eeeeeeee-2222-2222-2222-222222222222",
            threadId: legacyThreadId,
            authorName: "Codex",
            filePath: "Sources/LegacySandboxPolicy.swift",
            lineOld: 412,
            body:
              "I will add that note before approval so downstream users understand why the old permissive defaults disappeared.",
            timestamp: timestamp
          ),
        ]
      ),
      reviewThread(
        id: telemetryThreadId,
        state: "addressed",
        agentAcknowledgedAt: timestamp,
        comments: [
          reviewComment(
            id: "ffffffff-1111-1111-1111-111111111111",
            threadId: telemetryThreadId,
            authorName: "Noah",
            filePath: "Sources/ReviewTelemetryPlan.swift",
            lineNew: 318,
            body:
              "Thread state, draft count, and sandbox summary need to stay visible in the review screenshot.",
            timestamp: timestamp
          ),
          reviewComment(
            id: "ffffffff-2222-2222-2222-222222222222",
            threadId: telemetryThreadId,
            authorName: "Gemini",
            filePath: "Sources/ReviewTelemetryPlan.swift",
            lineNew: 650,
            body:
              "Addressed by keeping the telemetry plan explicit and pairing it with the pending draft summary.",
            timestamp: timestamp
          ),
        ]
      ),
    ]
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

  private static func createLinkedWorkspace() throws -> WorkspaceLaunchTarget {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-ui-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repoRoot = fixtureRoot.appendingPathComponent("repo", isDirectory: true)
    let worktreeRoot =
      fixtureRoot
      .appendingPathComponent("worktrees", isDirectory: true)
      .appendingPathComponent("feature-finalize", isDirectory: true)
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

    try "initial\n".write(
      to: repoRoot.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(repoRoot, ["add", "README.md"])
    try git(repoRoot, ["commit", "-m", "Initial commit"])
    try git(repoRoot, ["branch", "-M", "main"])
    try git(repoRoot, ["worktree", "add", "-b", "feature/finalize", worktreeRoot.path, "HEAD"])

    return WorkspaceLaunchTarget(
      fixtureRoot: fixtureRoot.path,
      repoRoot: repoRoot.path,
      repoCommonDir: repoRoot.appendingPathComponent(".git", isDirectory: true).path,
      selectedWorktreePath: worktreeRoot.path,
      argonHome: argonHome.path
    )
  }

  private static func createLazyRestoreWorkspace() throws -> RestoredWorkspaceLaunchTarget {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-ui-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repoRoot = fixtureRoot.appendingPathComponent("repo", isDirectory: true)
    let worktreeRoot =
      fixtureRoot
      .appendingPathComponent("worktrees", isDirectory: true)
      .appendingPathComponent("feature-lazy", isDirectory: true)
    let argonHome = fixtureRoot.appendingPathComponent("argon-home", isDirectory: true)
    let signalFile = fixtureRoot.appendingPathComponent("signal.txt")
    let snapshotFile = fixtureRoot.appendingPathComponent("workspace-snapshots.json")

    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: worktreeRoot.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
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
    try git(repoRoot, ["worktree", "add", "-b", "feature/lazy", worktreeRoot.path, "HEAD"])

    let snapshotPayload: [[String: Any]] = [
      [
        "target": [
          "repoRoot": repoRoot.path,
          "repoCommonDir": repoRoot.appendingPathComponent(".git", isDirectory: true).path,
          "selectedWorktreePath": repoRoot.path,
        ],
        "terminalTabsByWorktreePath": [
          repoRoot.path: [
            [
              "id": "11111111-1111-1111-1111-111111111111",
              "worktreePath": repoRoot.path,
              "worktreeLabel": "main",
              "title": "Base Shell",
              "commandDescription": "Sandboxed /bin/zsh",
              "kind": [
                "discriminator": "shell"
              ],
              "createdAt": 0,
              "isSandboxed": true,
              "writableRoots": [repoRoot.path],
            ]
          ],
          worktreeRoot.path: [
            [
              "id": "22222222-2222-2222-2222-222222222222",
              "worktreePath": worktreeRoot.path,
              "worktreeLabel": "feature/lazy",
              "title": "Feature Shell",
              "commandDescription": "Sandboxed /bin/zsh",
              "kind": [
                "discriminator": "shell"
              ],
              "createdAt": 1,
              "isSandboxed": true,
              "writableRoots": [worktreeRoot.path],
            ],
            [
              "id": "33333333-3333-3333-3333-333333333333",
              "worktreePath": worktreeRoot.path,
              "worktreeLabel": "feature/lazy",
              "title": "Missing Agent",
              "commandDescription": "/definitely/missing/agent --yolo",
              "kind": [
                "discriminator": "agent",
                "profileName": "Missing Agent",
                "icon": "terminal",
              ],
              "createdAt": 2,
              "isSandboxed": true,
              "writableRoots": [worktreeRoot.path],
            ],
          ],
        ],
        "selectedTerminalTabIDsByWorktreePath": [
          repoRoot.path: "11111111-1111-1111-1111-111111111111",
          worktreeRoot.path: "22222222-2222-2222-2222-222222222222",
        ],
      ]
    ]

    let snapshotData = try JSONSerialization.data(
      withJSONObject: snapshotPayload,
      options: [.prettyPrinted]
    )
    try snapshotData.write(to: snapshotFile, options: .atomic)

    return RestoredWorkspaceLaunchTarget(
      fixtureRoot: fixtureRoot.path,
      featureWorktreePath: worktreeRoot.path,
      argonHome: argonHome.path,
      snapshotFile: snapshotFile.path,
      signalFile: signalFile.path
    )
  }

  private static func createWebsiteWorkspace() throws -> WebsiteWorkspaceLaunchTarget {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-ui-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repoRoot = fixtureRoot.appendingPathComponent("repo", isDirectory: true)
    let worktreesRoot = fixtureRoot.appendingPathComponent("worktrees", isDirectory: true)
    let worktreeRoot =
      worktreesRoot
      .appendingPathComponent("feature-marketing", isDirectory: true)
    let reviewWorktreeRoot =
      worktreesRoot
      .appendingPathComponent("feature-review-pass", isDirectory: true)
    let releaseWorktreeRoot =
      worktreesRoot
      .appendingPathComponent("chore-release-pipeline", isDirectory: true)
    let sandboxWorktreeRoot =
      worktreesRoot
      .appendingPathComponent("fix-sandbox-network", isDirectory: true)
    let connectorsWorktreeRoot =
      worktreesRoot
      .appendingPathComponent("feat-mcp-connectors", isDirectory: true)
    let designWorktreeRoot =
      worktreesRoot
      .appendingPathComponent("design-welcome-refresh", isDirectory: true)
    let argonHome = fixtureRoot.appendingPathComponent("argon-home", isDirectory: true)
    let signalFile = fixtureRoot.appendingPathComponent("signal.txt")

    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: argonHome, withIntermediateDirectories: true)

    try git(repoRoot, ["init"])
    try git(repoRoot, ["config", "user.name", "Argon UI Test"])
    try git(repoRoot, ["config", "user.email", "argon-ui-test@example.com"])

    try """
    # Argon

    Native workspace for coding agents.
    """
    .write(
      to: repoRoot.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createDirectory(
      at: repoRoot.appendingPathComponent("Docs", isDirectory: true),
      withIntermediateDirectories: true
    )

    try FileManager.default.createDirectory(
      at: repoRoot.appendingPathComponent("Sources", isDirectory: true),
      withIntermediateDirectories: true
    )

    try """
    struct WorkspaceShell {
        let title: String
    }
    """
    .write(
      to: repoRoot.appendingPathComponent("Sources/WorkspaceShell.swift"),
      atomically: true,
      encoding: .utf8
    )

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Sources/LegacyAutomationMatrix.swift"),
      header: [
        "enum LegacyAutomationMatrix {",
        "    static let checkpoints = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 360
    ) { index in
      "        \"legacy-checkpoint-\(String(format: "%03d", index)): prompt copy, shell replay, manual review\","
    }

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Docs/legacy-review-flow.md"),
      header: ["# Legacy review flow", ""],
      count: 240
    ) { index in
      "- Step \(String(format: "%03d", index)): copy a prompt, inspect a terminal, then reconcile the notes by hand."
    }

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Docs/release-runbook.md"),
      header: ["# Release runbook", ""],
      count: 220
    ) { index in
      "- Gate \(String(format: "%03d", index)): verify signing, appcast, Homebrew, and website publishing."
    }

    try git(repoRoot, ["add", "."])
    try git(repoRoot, ["commit", "-m", "Initial commit"])
    try git(repoRoot, ["branch", "-M", "main"])
    try git(repoRoot, ["worktree", "add", "-b", "feature/marketing", worktreeRoot.path, "HEAD"])
    try git(
      repoRoot,
      ["worktree", "add", "-b", "feature/review-pass", reviewWorktreeRoot.path, "HEAD"]
    )
    try git(
      repoRoot,
      ["worktree", "add", "-b", "chore/release-pipeline", releaseWorktreeRoot.path, "HEAD"]
    )
    try git(
      repoRoot,
      ["worktree", "add", "-b", "fix/sandbox-network", sandboxWorktreeRoot.path, "HEAD"]
    )
    try git(
      repoRoot,
      ["worktree", "add", "-b", "feat/mcp-connectors", connectorsWorktreeRoot.path, "HEAD"]
    )
    try git(
      repoRoot,
      ["worktree", "add", "-b", "design/welcome-refresh", designWorktreeRoot.path, "HEAD"]
    )
    try FileManager.default.createDirectory(
      at: worktreeRoot.appendingPathComponent("Docs", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: reviewWorktreeRoot.appendingPathComponent("Docs", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: releaseWorktreeRoot.appendingPathComponent(".github/workflows", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: sandboxWorktreeRoot.appendingPathComponent("Docs", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: connectorsWorktreeRoot.appendingPathComponent("Docs", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: connectorsWorktreeRoot.appendingPathComponent("Sources", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: designWorktreeRoot.appendingPathComponent("website", isDirectory: true),
      withIntermediateDirectories: true
    )

    try """
    enum SiteCopy {
        static let headline = "The control plane for local coding agents."
        static let subheadline = "Native worktrees, terminals, and review."
    }
    """
    .write(
      to: worktreeRoot.appendingPathComponent("Sources/SiteCopy.swift"),
      atomically: true,
      encoding: .utf8
    )

    try writeGeneratedLines(
      to: worktreeRoot.appendingPathComponent("Sources/AgentLaunchPlan.swift"),
      header: [
        "enum AgentLaunchPlan {",
        "    static let phases = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 260
    ) { index in
      "        \"phase-\(String(format: "%03d", index)): create worktree, launch agent, collect review evidence\","
    }
    try writeGeneratedLines(
      to: worktreeRoot.appendingPathComponent("Docs/review-loop.md"),
      header: ["# Review loop", ""],
      count: 280
    ) { index in
      "- Loop \(String(format: "%03d", index)): compare the branch, capture a comment, ask the agent to respond, then keep the decision explicit."
    }
    try git(
      worktreeRoot,
      ["add", "Sources/SiteCopy.swift", "Sources/AgentLaunchPlan.swift", "Docs/review-loop.md"]
    )
    try git(worktreeRoot, ["commit", "-m", "Draft website copy"])

    try """
    # Review dry run

    - request changes on network copy
    - tighten summary handoff wording
    - validate the finalize actions
    """
    .write(
      to: reviewWorktreeRoot.appendingPathComponent("Docs/review-dry-run.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(reviewWorktreeRoot, ["add", "Docs/review-dry-run.md"])
    try git(reviewWorktreeRoot, ["commit", "-m", "Seed review fixture"])

    try writeGeneratedLines(
      to: releaseWorktreeRoot.appendingPathComponent(".github/workflows/release.yml"),
      header: [
        "name: release",
        "on:",
        "  workflow_dispatch:",
        "  push:",
        "    tags:",
        "      - 'v*'",
        "jobs:",
        "  notarize:",
        "    runs-on: macos-26",
        "    steps:",
        "      - uses: actions/checkout@v6",
      ],
      count: 340
    ) { index in
      "      - name: release gate \(String(format: "%03d", index))\n        run: ./scripts/release-gate --check gate-\(String(format: "%03d", index)) --require-signed-artifacts"
    }
    try git(releaseWorktreeRoot, ["add", ".github/workflows/release.yml"])
    try git(releaseWorktreeRoot, ["commit", "-m", "Draft release workflow"])

    try """
    # Sandbox notes

    - audit trust store reads
    - keep proxy logging visible in the inspector
    - document direct connect limitations
    """
    .write(
      to: sandboxWorktreeRoot.appendingPathComponent("Docs/sandbox-audit.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(sandboxWorktreeRoot, ["add", "Docs/sandbox-audit.md"])
    try git(sandboxWorktreeRoot, ["commit", "-m", "Capture sandbox follow-ups"])

    try """
    enum ConnectorCatalog {
        static let planned = [
            "Linear",
            "Slack",
            "Sentry",
        ]
    }
    """
    .write(
      to: connectorsWorktreeRoot.appendingPathComponent("Sources/ConnectorCatalog.swift"),
      atomically: true,
      encoding: .utf8
    )
    try """
    # MCP connector sketch

    - connectors managed from one native place
    - expose them to agents through the in-app MCP server
    - keep secrets out of prompts
    """
    .write(
      to: connectorsWorktreeRoot.appendingPathComponent("Docs/mcp-connectors.md"),
      atomically: true,
      encoding: .utf8
    )
    try writeGeneratedLines(
      to: connectorsWorktreeRoot.appendingPathComponent("Sources/ConnectorPermissionMatrix.swift"),
      header: [
        "enum ConnectorPermissionMatrix {",
        "    static let rules = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 320
    ) { index in
      "        \"connector-\(String(format: "%03d", index)): prompt redaction, scoped token, audit entry\","
    }
    try writeGeneratedLines(
      to: connectorsWorktreeRoot.appendingPathComponent("Docs/connector-rollout.md"),
      header: ["# Connector rollout", ""],
      count: 260
    ) { index in
      "- Scenario \(String(format: "%03d", index)): map a repository signal to a scoped connector action before agent launch."
    }
    try git(
      connectorsWorktreeRoot,
      [
        "add",
        "Sources/ConnectorCatalog.swift",
        "Sources/ConnectorPermissionMatrix.swift",
        "Docs/mcp-connectors.md",
        "Docs/connector-rollout.md",
      ]
    )
    try git(connectorsWorktreeRoot, ["commit", "-m", "Sketch connector catalog"])

    try """
    <section class="hero">
      <h1>Argon</h1>
      <p>Workspace control for coding agents.</p>
    </section>
    """
    .write(
      to: designWorktreeRoot.appendingPathComponent("website/hero.html"),
      atomically: true,
      encoding: .utf8
    )
    try git(designWorktreeRoot, ["add", "website/hero.html"])
    try git(designWorktreeRoot, ["commit", "-m", "Draft welcome split layout"])

    try """
    ## Contributing

    Open worktrees in Argon or with `argon <dir>`.
    """
    .write(
      to: repoRoot.appendingPathComponent("CONTRIBUTING.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(repoRoot, ["add", "CONTRIBUTING.md"])
    try git(repoRoot, ["commit", "-m", "Add contributor guide"])

    try """
    # Argon

    Native workspace for coding agents.

    - worktrees
    - embedded terminals
    - native review
    """
    .write(
      to: worktreeRoot.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )

    try writeGeneratedLines(
      to: worktreeRoot.appendingPathComponent("Sources/WorkspaceShell.swift"),
      header: [
        "struct WorkspaceShell {",
        "    let title = \"Argon\"",
        "    let supportsSandbox = true",
        "    let supportsReviews = true",
        "",
        "    static let visibleWorkflows = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 320
    ) { index in
      "        \"workflow-\(String(format: "%03d", index)): worktree, terminal, sandbox event, review checkpoint\","
    }

    try writeGeneratedLines(
      to: worktreeRoot.appendingPathComponent("Sources/SiteCopy.swift"),
      header: [
        "enum SiteCopy {",
        "    static let headline = \"A workspace for coding agents\"",
        "    static let subheadline = \"Run agents in isolated worktrees, watch their terminals, and review before merge.\"",
        "    static let proofPoints = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 300
    ) { index in
      "        \"proof-\(String(format: "%03d", index)): agent output stays paired with the diff and review decision\","
    }

    try writeGeneratedLines(
      to: worktreeRoot.appendingPathComponent("Sources/InspectorCopy.swift"),
      header: [
        "struct InspectorCopy {",
        "    static let summary = \"Observed proxied traffic, review handoff, and worktree actions live in one native workspace.\"",
        "    static let events = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 240
    ) { index in
      "        \"event-\(String(format: "%03d", index)): sandbox boundary changed after reviewer confirmation\","
    }

    try writeGeneratedLines(
      to: worktreeRoot.appendingPathComponent("Docs/marketing-notes.md"),
      header: ["# Marketing notes", ""],
      count: 360
    ) { index in
      "- Note \(String(format: "%03d", index)): show how a local agent can explore safely, surface the diff, and hand control back to the reviewer."
    }

    try FileManager.default.removeItem(
      at: worktreeRoot.appendingPathComponent("Sources/LegacyAutomationMatrix.swift")
    )

    try writeGeneratedLines(
      to: sandboxWorktreeRoot.appendingPathComponent("Docs/sandbox-audit.md"),
      header: ["# Sandbox notes", ""],
      count: 260
    ) { index in
      "- Audit \(String(format: "%03d", index)): capture trust-store reads, proxy routing, denied writes, and the reviewer-facing reason."
    }

    try writeGeneratedLines(
      to: connectorsWorktreeRoot.appendingPathComponent("Docs/mcp-connectors.md"),
      header: ["# MCP connector sketch", ""],
      count: 420
    ) { index in
      "- Connector pass \(String(format: "%03d", index)): expose a scoped service to the agent, record the boundary, and keep secrets out of prompts."
    }

    try writeGeneratedLines(
      to: connectorsWorktreeRoot.appendingPathComponent("Sources/ConnectorCatalog.swift"),
      header: [
        "enum ConnectorCatalog {",
        "    static let planned = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 380
    ) { index in
      "        \"service-\(String(format: "%03d", index)): scoped read, redacted prompt, visible audit trail\","
    }

    try FileManager.default.removeItem(
      at: connectorsWorktreeRoot.appendingPathComponent("Docs/legacy-review-flow.md")
    )

    try writeGeneratedLines(
      to: designWorktreeRoot.appendingPathComponent("website/hero.html"),
      header: [
        "<section class=\"hero\">",
        "  <h1>Argon</h1>",
        "  <p>Workspace control for coding agents.</p>",
        "  <ul>",
      ],
      footer: [
        "  </ul>",
        "</section>",
      ],
      count: 220
    ) { index in
      "    <li>Flow \(String(format: "%03d", index)): create a worktree, run an agent, review the diff, then merge back.</li>"
    }

    return WebsiteWorkspaceLaunchTarget(
      fixtureRoot: fixtureRoot.path,
      repoRoot: repoRoot.path,
      repoCommonDir: repoRoot.appendingPathComponent(".git", isDirectory: true).path,
      selectedWorktreePath: worktreeRoot.path,
      reviewWorktreePath: reviewWorktreeRoot.path,
      sandboxWorktreePath: sandboxWorktreeRoot.path,
      connectorsWorktreePath: connectorsWorktreeRoot.path,
      argonHome: argonHome.path,
      signalFile: signalFile.path
    )
  }

  private static func createWebsiteReviewSession() throws -> WebsiteReviewLaunchTarget {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-ui-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repoRoot = fixtureRoot.appendingPathComponent("repo", isDirectory: true)
    let argonHome = fixtureRoot.appendingPathComponent("argon-home", isDirectory: true)
    let signalFile = fixtureRoot.appendingPathComponent("signal.txt")
    let sessionId = UUID().uuidString.lowercased()

    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: argonHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: repoRoot.appendingPathComponent("Sources", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: repoRoot.appendingPathComponent("Docs", isDirectory: true),
      withIntermediateDirectories: true
    )

    try git(repoRoot, ["init"])
    try git(repoRoot, ["config", "user.name", "Argon UI Test"])
    try git(repoRoot, ["config", "user.email", "argon-ui-test@example.com"])

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Sources/WorkspaceShell.swift"),
      header: [
        "struct WorkspaceShell {",
        "    let title = \"Argon\"",
        "    let supportsSandbox = false",
        "    static let launchChecklist = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 220
    ) { index in
      "        \"baseline-\(String(format: "%03d", index)): start terminal, copy prompt, review manually\","
    }
    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Docs/sandbox.md"),
      header: ["# Sandbox", ""],
      count: 180
    ) { index in
      "- Baseline \(String(format: "%03d", index)): network defaults are still under review and need manual verification."
    }
    try """
    ENV DEFAULT NONE
    FS DEFAULT NONE
    EXEC DEFAULT ALLOW
    USE os
    USE shell
    """
    .write(
      to: repoRoot.appendingPathComponent("Sandboxfile"),
      atomically: true,
      encoding: .utf8
    )

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Sources/LegacySandboxPolicy.swift"),
      header: [
        "enum LegacySandboxPolicy {",
        "    static let assumptions = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 520
    ) { index in
      "        \"assumption-\(String(format: "%03d", index)): permissive network behavior documented outside the review path\","
    }

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Sources/AgentReviewOrchestrator.swift"),
      header: [
        "struct AgentReviewOrchestrator {",
        "    static let steps = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 260
    ) { index in
      "        \"step-\(String(format: "%03d", index)): collect terminal output, diff context, and reviewer notes\","
    }

    try git(repoRoot, ["add", "."])
    try git(repoRoot, ["commit", "-m", "Initial review fixture"])
    try git(repoRoot, ["branch", "-M", "main"])

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Sources/WorkspaceShell.swift"),
      header: [
        "struct WorkspaceShell {",
        "    let title = \"Argon\"",
        "    let supportsSandbox = true",
        "    let supportsReviews = true",
        "    static let launchChecklist = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 420
    ) { index in
      "        \"sandboxed-\(String(format: "%03d", index)): create worktree, run agent, review diff, and keep the boundary visible\","
    }
    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Docs/sandbox.md"),
      header: ["# Sandbox", ""],
      count: 420
    ) { index in
      "- Policy \(String(format: "%03d", index)): network defaults are explicit, proxy traffic is visible, and denied writes stay attached to the review."
    }
    try """
    ENV DEFAULT NONE
    FS DEFAULT NONE
    EXEC DEFAULT ALLOW
    NET DEFAULT NONE
    NET ALLOW PROXY *
    USE os
    USE shell
    USE git
    USE agent
    FS ALLOW READ .
    FS ALLOW WRITE .
    """
    .write(
      to: repoRoot.appendingPathComponent("Sandboxfile"),
      atomically: true,
      encoding: .utf8
    )
    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Sources/ReviewFlow.swift"),
      header: [
        "struct ReviewFlow {",
        "    static let headline = \"Keep coding, review, and merge-back in one app.\"",
        "    static let checkpoints = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 360
    ) { index in
      "        \"checkpoint-\(String(format: "%03d", index)): reviewer comment, agent reply, visible decision\","
    }

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Sources/AgentReviewOrchestrator.swift"),
      header: [
        "struct AgentReviewOrchestrator {",
        "    static let steps = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 560
    ) { index in
      "        \"step-\(String(format: "%03d", index)): route comment context to the right agent and wait for an explicit response\","
    }

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Sources/SandboxPolicyManifest.swift"),
      header: [
        "enum SandboxPolicyManifest {",
        "    static let grants = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 940
    ) { index in
      "        \"grant-\(String(format: "%03d", index)): allow read scope, deny write escape, log network proxy decision\","
    }

    try writeGeneratedLines(
      to: repoRoot.appendingPathComponent("Sources/ReviewTelemetryPlan.swift"),
      header: [
        "enum ReviewTelemetryPlan {",
        "    static let events = [",
      ],
      footer: [
        "    ]",
        "}",
      ],
      count: 760
    ) { index in
      "        \"event-\(String(format: "%03d", index)): capture thread state, draft count, and sandbox summary\","
    }

    try FileManager.default.removeItem(
      at: repoRoot.appendingPathComponent("Sources/LegacySandboxPolicy.swift")
    )

    let sessionsDirectory = sessionsDirectory(argonHome: argonHome.path, repoRoot: repoRoot.path)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: sessionsDirectory),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: sessionsDirectory).appendingPathComponent("drafts"),
      withIntermediateDirectories: true
    )

    let timestamp = iso8601Timestamp()
    let sessionPayload: [String: Any] = [
      "id": sessionId,
      "repo_root": repoRoot.path,
      "mode": "uncommitted",
      "base_ref": "HEAD",
      "head_ref": "WORKTREE",
      "merge_base_sha": "HEAD",
      "change_summary":
        "Tightens sandbox defaults and keeps review plus merge-back in one native loop.",
      "status": "awaiting_reviewer",
      "threads": websiteReviewThreads(timestamp: timestamp),
      "decision": NSNull(),
      "agent_last_seen_at": timestamp,
      "created_at": timestamp,
      "updated_at": timestamp,
    ]

    let sessionFile = URL(fileURLWithPath: sessionsDirectory).appendingPathComponent(
      "\(sessionId).json")
    let sessionData = try JSONSerialization.data(
      withJSONObject: sessionPayload,
      options: [.prettyPrinted]
    )
    try sessionData.write(to: sessionFile, options: .atomic)

    let draftPayload: [String: Any] = [
      "session_id": sessionId,
      "comments": [
        [
          "id": "cccccccc-1111-1111-1111-111111111111",
          "thread_id": NSNull(),
          "anchor": [
            "file_path": "Docs/sandbox.md",
            "line_new": 3,
            "line_old": NSNull(),
          ],
          "body": "Mention that sandboxing is the default for integrated agent launches.",
          "created_at": timestamp,
          "updated_at": timestamp,
        ],
        [
          "id": "cccccccc-2222-2222-2222-222222222222",
          "thread_id": NSNull(),
          "anchor": [
            "file_path": "Sources/ReviewFlow.swift",
            "line_new": 210,
            "line_old": NSNull(),
          ],
          "body": "Ask for one final pass on the merge-back language before approval.",
          "created_at": timestamp,
          "updated_at": timestamp,
        ],
        [
          "id": "cccccccc-3333-3333-3333-333333333333",
          "thread_id": NSNull(),
          "anchor": [
            "file_path": "Sources/LegacySandboxPolicy.swift",
            "line_new": NSNull(),
            "line_old": 88,
          ],
          "body": "Confirm no migration path still imports the deleted legacy policy.",
          "created_at": timestamp,
          "updated_at": timestamp,
        ],
      ],
      "created_at": timestamp,
      "updated_at": timestamp,
    ]
    let draftFile = URL(fileURLWithPath: sessionsDirectory)
      .appendingPathComponent("drafts")
      .appendingPathComponent("\(sessionId).json")
    let draftData = try JSONSerialization.data(
      withJSONObject: draftPayload,
      options: [.prettyPrinted]
    )
    try draftData.write(to: draftFile, options: .atomic)

    return WebsiteReviewLaunchTarget(
      fixtureRoot: fixtureRoot.path,
      sessionId: sessionId,
      repoRoot: repoRoot.path,
      argonHome: argonHome.path,
      signalFile: signalFile.path
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

  private static func websiteScreenshotUsesLiveAgents() -> Bool {
    let configURL = URL(fileURLWithPath: repositoryRoot())
      .appendingPathComponent("website")
      .appendingPathComponent(screenshotLiveAgentsConfigFileName)
    guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
    return ["1", "true", "yes", "on"].contains(
      contents.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    )
  }

  private static func websiteReviewersJSON(useLiveAgents: Bool) -> String {
    let launches: [[String: Any]] =
      if useLiveAgents {
        [
          [
            "name": "Codex",
            "command": "codex",
            "focusPrompt": "Review the branch for merge-back safety and sandbox clarity.",
            "sandboxEnabled": true,
            "icon": "codex",
          ],
          [
            "name": "Gemini",
            "command": "gemini",
            "focusPrompt": "Review the branch for product copy and reviewer handoff clarity.",
            "sandboxEnabled": true,
            "icon": "gemini",
          ],
        ]
      } else {
        [
          [
            "name": "Codex",
            "command":
              "/bin/sh -lc 'printf \"Codex reviewer\\n\\nGemini already pushed on the product copy.\\nI am checking merge-back safety and the sandbox wording before land.\\n\\n- keep sandbox-on-by-default explicit\\n- make proxy activity visible before merge-back\\n\"; sleep 180'",
            "focusPrompt":
              "Review the branch for merge-back safety and sandbox clarity, then coordinate with Gemini on the final wording.",
            "sandboxEnabled": true,
            "icon": "codex",
          ],
          [
            "name": "Gemini",
            "command":
              "/bin/sh -lc 'printf \"Gemini reviewer\\n\\nCodex is checking merge-back safety.\\nI am tightening the reviewer handoff and approval language.\\n\\n- make the human approval gate explicit\\n- keep the copy local-first and concrete\\n\"; sleep 180'",
            "focusPrompt":
              "Review the branch for product copy and reviewer handoff clarity, then align with Codex on what should block merge-back.",
            "sandboxEnabled": true,
            "icon": "gemini",
          ],
        ]
      }

    let data = try! JSONSerialization.data(withJSONObject: launches, options: [])
    return String(decoding: data, as: UTF8.self)
  }

  @MainActor
  private static func attachScreenshot(_ screenshot: XCUIScreenshot, named name: String) {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "Capture \(name)") { activity in
      activity.add(attachment)
    }
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

  private func waitForSignalCount(
    _ expected: String,
    at url: URL,
    expectedCount: Int,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if signalCount(expected, at: url) >= expectedCount {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return false
  }

  private func signalCount(_ expected: String, at url: URL) -> Int {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
    return
      contents
      .split(separator: "\n")
      .filter { $0 == expected }
      .count
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
