import Foundation
import Testing
import UserNotifications

@testable import Argon

@Suite("WorkspaceTerminalAttentionNotifier")
struct WorkspaceTerminalAttentionNotifierTests {
  @Test("bell notifications use compact terminal context")
  @MainActor
  func bellNotificationsUseCompactTerminalContext() {
    let tab = makeTab(title: "Codex", worktreeLabel: "feature/login")

    let display = WorkspaceTerminalAttentionNotifier.notificationDisplay(
      for: .bell,
      repoRoot: "/tmp/argon",
      tab: tab,
      context: WorkspaceTerminalNotificationContext(showsProject: true, showsWorkspace: true)
    )

    #expect(display?.title == "Bell")
    #expect(display?.subtitle == "argon • feature/login")
    #expect(display?.body == "")
  }

  @Test("untitled terminal notifications keep the message in the body")
  @MainActor
  func untitledTerminalNotificationsKeepTheMessageInTheBody() {
    let tab = makeTab(title: "Privileged Shell 1", worktreeLabel: "main")

    let display = WorkspaceTerminalAttentionNotifier.notificationDisplay(
      for: .desktopNotification(title: "", body: "hello"),
      repoRoot: "/tmp/argon",
      tab: tab,
      context: WorkspaceTerminalNotificationContext(showsProject: false, showsWorkspace: false)
    )

    #expect(display?.title == "Argon")
    #expect(display?.subtitle == "")
    #expect(display?.body == "hello")
  }

  @Test("terminal notifications include project context only when requested")
  @MainActor
  func terminalNotificationsIncludeProjectContextOnlyWhenRequested() {
    let tab = makeTab(title: "Privileged Shell 1", worktreeLabel: "main")

    let display = WorkspaceTerminalAttentionNotifier.notificationDisplay(
      for: .desktopNotification(title: "", body: "hello"),
      repoRoot: "/tmp/argon",
      tab: tab,
      context: WorkspaceTerminalNotificationContext(showsProject: true, showsWorkspace: false)
    )

    #expect(display?.title == "Argon")
    #expect(display?.subtitle == "argon")
    #expect(display?.body == "hello")
  }

  @Test("titled terminal notifications keep the message in the body")
  @MainActor
  func titledTerminalNotificationsKeepTheMessageInTheBody() {
    let tab = makeTab(title: "Codex", worktreeLabel: "main")

    let display = WorkspaceTerminalAttentionNotifier.notificationDisplay(
      for: .desktopNotification(title: "Approval needed", body: "Run tests?"),
      repoRoot: "/tmp/argon",
      tab: tab,
      context: WorkspaceTerminalNotificationContext(showsProject: true, showsWorkspace: true)
    )

    #expect(display?.title == "Argon")
    #expect(display?.subtitle == "argon • main")
    #expect(display?.body == "Run tests?")
  }

  @Test("command finished notifications omit context for a single project workspace")
  @MainActor
  func commandFinishedNotificationsOmitContextForSingleProjectWorkspace() {
    let tab = makeTab(title: "Shell 1", worktreeLabel: "main")

    let display = WorkspaceTerminalAttentionNotifier.notificationDisplay(
      for: .commandFinished(exitCode: 0, durationNanoseconds: 2_000_000_000),
      repoRoot: "/tmp/argon",
      tab: tab,
      context: WorkspaceTerminalNotificationContext(showsProject: false, showsWorkspace: false)
    )

    #expect(display?.title == "Command finished")
    #expect(display?.subtitle == "")
    #expect(display?.body.contains("Exited with code 0 after") == true)
  }

  @Test("agent launch permission flow requests authorization when enabled and undetermined")
  @MainActor
  func agentLaunchPermissionFlowRequestsAuthorizationWhenEnabledAndUndetermined() async {
    let defaults = makeUserDefaults()
    let notificationCenter = FakeWorkspaceUserNotificationCenter(status: .notDetermined)
    let explainer = FakeAgentNotificationPermissionExplainer(shouldConfirm: true)
    let notifier = WorkspaceTerminalAttentionNotifier(
      notificationCenter: notificationCenter,
      userDefaults: defaults,
      permissionExplainer: explainer
    )

    await notifier.prepareForAgentTabLaunch()

    #expect(explainer.confirmationCount == 1)
    #expect(notificationCenter.requestAuthorizationCount == 1)
    #expect(AgentNotificationSettings.isEnabled(userDefaults: defaults))
    #expect(notifier.authorizationStatus == .authorized)
  }

  @Test("agent launch permission flow keeps setting on when permission is denied")
  @MainActor
  func agentLaunchPermissionFlowKeepsSettingOnWhenPermissionIsDenied() async {
    let defaults = makeUserDefaults()
    let notificationCenter = FakeWorkspaceUserNotificationCenter(status: .denied)
    let explainer = FakeAgentNotificationPermissionExplainer(shouldConfirm: true)
    let notifier = WorkspaceTerminalAttentionNotifier(
      notificationCenter: notificationCenter,
      userDefaults: defaults,
      permissionExplainer: explainer
    )

    await notifier.prepareForAgentTabLaunch()

    #expect(explainer.confirmationCount == 0)
    #expect(notificationCenter.requestAuthorizationCount == 0)
    #expect(AgentNotificationSettings.isEnabled(userDefaults: defaults))
    #expect(notifier.authorizationStatus == .denied)
  }

  @Test("settings toggle stays on when system permission is denied")
  @MainActor
  func settingsToggleStaysOnWhenSystemPermissionIsDenied() async {
    let defaults = makeUserDefaults()
    AgentNotificationSettings.setEnabled(false, userDefaults: defaults)
    let notificationCenter = FakeWorkspaceUserNotificationCenter(status: .denied)
    let explainer = FakeAgentNotificationPermissionExplainer(shouldConfirm: true)
    let notifier = WorkspaceTerminalAttentionNotifier(
      notificationCenter: notificationCenter,
      userDefaults: defaults,
      permissionExplainer: explainer
    )

    let result = await notifier.setAgentNotificationsEnabledFromSettings(true)

    #expect(result == .disabledBySystemPermission)
    #expect(explainer.confirmationCount == 0)
    #expect(notificationCenter.requestAuthorizationCount == 0)
    #expect(AgentNotificationSettings.isEnabled(userDefaults: defaults))
    #expect(notifier.authorizationStatus == .denied)
  }

  @Test("system prompt denial keeps setting on")
  @MainActor
  func systemPromptDenialKeepsSettingOn() async {
    let defaults = makeUserDefaults()
    let notificationCenter = FakeWorkspaceUserNotificationCenter(status: .notDetermined)
    notificationCenter.shouldGrantAuthorization = false
    let explainer = FakeAgentNotificationPermissionExplainer(shouldConfirm: true)
    let notifier = WorkspaceTerminalAttentionNotifier(
      notificationCenter: notificationCenter,
      userDefaults: defaults,
      permissionExplainer: explainer
    )

    let result = await notifier.prepareForAgentTabLaunch()

    #expect(result == .disabledBySystemPermission)
    #expect(explainer.confirmationCount == 1)
    #expect(notificationCenter.requestAuthorizationCount == 1)
    #expect(AgentNotificationSettings.isEnabled(userDefaults: defaults))
    #expect(notifier.authorizationStatus == .denied)
  }

  @Test("settings enable clears suppressed launch warning after authorization")
  @MainActor
  func settingsEnableClearsSuppressedLaunchWarningAfterAuthorization() async {
    let defaults = makeUserDefaults()
    AgentNotificationSettings.setEnabled(false, userDefaults: defaults)
    AgentNotificationSettings.setSuppressSystemDeniedLaunchWarning(true, userDefaults: defaults)
    let notificationCenter = FakeWorkspaceUserNotificationCenter(status: .notDetermined)
    let explainer = FakeAgentNotificationPermissionExplainer(shouldConfirm: true)
    let notifier = WorkspaceTerminalAttentionNotifier(
      notificationCenter: notificationCenter,
      userDefaults: defaults,
      permissionExplainer: explainer
    )

    let result = await notifier.setAgentNotificationsEnabledFromSettings(true)

    #expect(result == .enabled)
    #expect(AgentNotificationSettings.isEnabled(userDefaults: defaults))
    #expect(AgentNotificationSettings.shouldShowSystemDeniedLaunchWarning(userDefaults: defaults))
  }

  @MainActor
  private func makeTab(
    title: String,
    worktreeLabel: String
  ) -> WorkspaceTerminalTab {
    WorkspaceTerminalTab(
      worktreePath: "/tmp/argon",
      worktreeLabel: worktreeLabel,
      title: title,
      commandDescription: "echo hi",
      kind: .agent(profileName: title, icon: "codex"),
      launch: .command("echo hi", currentDirectory: "/tmp/argon")
    )
  }

  private func makeUserDefaults() -> UserDefaults {
    let suiteName = "WorkspaceTerminalAttentionNotifierTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}

@MainActor
private final class FakeWorkspaceUserNotificationCenter: WorkspaceUserNotificationCenter {
  var delegate: UNUserNotificationCenterDelegate?
  var status: UNAuthorizationStatus
  var requestAuthorizationCount = 0
  var addedNotificationCount = 0
  var shouldGrantAuthorization = true

  init(status: UNAuthorizationStatus) {
    self.status = status
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    status
  }

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    requestAuthorizationCount += 1
    if shouldGrantAuthorization {
      status = .authorized
      return true
    }

    status = .denied
    return false
  }

  func add(_ request: UNNotificationRequest) async throws {
    addedNotificationCount += 1
  }
}

@MainActor
private final class FakeAgentNotificationPermissionExplainer: AgentNotificationPermissionExplaining
{
  let shouldConfirm: Bool
  var confirmationCount = 0

  init(shouldConfirm: Bool) {
    self.shouldConfirm = shouldConfirm
  }

  func shouldRequestAgentNotificationPermission(
    source: AgentNotificationPermissionRequestSource
  ) -> Bool {
    confirmationCount += 1
    return shouldConfirm
  }
}
