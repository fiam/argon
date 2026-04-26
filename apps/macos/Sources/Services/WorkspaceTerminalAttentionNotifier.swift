import AppKit
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class WorkspaceTerminalAttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
  private enum UserInfoKey {
    static let repoRoot = "repoRoot"
    static let worktreePath = "worktreePath"
    static let terminalTabID = "terminalTabID"
  }

  @ObservationIgnored
  private let notificationCenter: any WorkspaceUserNotificationCenter
  @ObservationIgnored
  private let userDefaults: UserDefaults
  @ObservationIgnored
  private let permissionExplainer: any AgentNotificationPermissionExplaining
  @ObservationIgnored
  private weak var workspaceWindowRegistry: WorkspaceWindowRegistry?
  @ObservationIgnored
  private var isRequestingPermission = false

  private(set) var authorizationStatus: AgentNotificationAuthorizationStatus = .unknown

  init(
    notificationCenter: any WorkspaceUserNotificationCenter = UNUserNotificationCenter.current(),
    userDefaults: UserDefaults = .standard,
    permissionExplainer: any AgentNotificationPermissionExplaining =
      AgentNotificationPermissionAlertPresenter()
  ) {
    self.notificationCenter = notificationCenter
    self.userDefaults = userDefaults
    self.permissionExplainer = permissionExplainer
    super.init()
    self.notificationCenter.delegate = self
  }

  func bind(workspaceWindowRegistry: WorkspaceWindowRegistry) {
    self.workspaceWindowRegistry = workspaceWindowRegistry
    if notificationCenter.delegate !== self {
      notificationCenter.delegate = self
    }
  }

  @discardableResult
  func prepareForAgentTabLaunch() async -> AgentNotificationPreferenceUpdateResult {
    guard AgentNotificationSettings.isEnabled(userDefaults: userDefaults) else {
      let status = await refreshAuthorizationStatus()
      return status == .denied ? .disabledBySystemPermission : .disabled
    }

    return await enableAgentNotifications(requestSource: .agentLaunch)
  }

  @discardableResult
  func setAgentNotificationsEnabledFromSettings(_ isEnabled: Bool) async
    -> AgentNotificationPreferenceUpdateResult
  {
    guard isEnabled else {
      AgentNotificationSettings.setEnabled(false, userDefaults: userDefaults)
      _ = await refreshAuthorizationStatus()
      return .disabled
    }

    return await enableAgentNotifications(requestSource: .settings)
  }

  @discardableResult
  func refreshAuthorizationStatus() async -> AgentNotificationAuthorizationStatus {
    let status = AgentNotificationAuthorizationStatus(
      await notificationCenter.authorizationStatus()
    )
    authorizationStatus = status
    if status == .denied {
      AgentNotificationSettings.setEnabled(true, userDefaults: userDefaults)
    }
    return status
  }

  func openSystemNotificationSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    else {
      return
    }

    NSWorkspace.shared.open(url)
  }

  func postAttentionNotification(
    event: TerminalAttentionEvent,
    repoRoot: String,
    tab: WorkspaceTerminalTab
  ) {
    guard let content = notificationContent(for: event, repoRoot: repoRoot, tab: tab) else {
      return
    }
    Task {
      await deliver(content: content)
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let payload = response.notification.request.content.userInfo
    let activation = Self.activationTarget(from: payload)
    completionHandler()

    guard let activation else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      _ = self.workspaceWindowRegistry?.focusTerminal(
        repoRoot: activation.repoRoot,
        worktreePath: activation.worktreePath,
        tabID: activation.terminalTabID
      )
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  private func deliver(content: UNMutableNotificationContent) async {
    guard AgentNotificationSettings.isEnabled(userDefaults: userDefaults) else { return }

    guard await refreshAuthorizationStatus() == .authorized else { return }

    let request = UNNotificationRequest(
      identifier: "argon.workspace-terminal.\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    try? await notificationCenter.add(request)
  }

  private func enableAgentNotifications(
    requestSource: AgentNotificationPermissionRequestSource
  ) async -> AgentNotificationPreferenceUpdateResult {
    guard !isRequestingPermission else { return .requestInProgress }

    switch await refreshAuthorizationStatus() {
    case .authorized:
      AgentNotificationSettings.setEnabled(true, userDefaults: userDefaults)
      AgentNotificationSettings.setSuppressSystemDeniedLaunchWarning(
        false,
        userDefaults: userDefaults
      )
      return .enabled
    case .denied:
      AgentNotificationSettings.setEnabled(true, userDefaults: userDefaults)
      return .disabledBySystemPermission
    case .unknown:
      return .disabledBySystemPermission
    case .notDetermined:
      break
    }

    guard permissionExplainer.shouldRequestAgentNotificationPermission(source: requestSource)
    else {
      AgentNotificationSettings.setEnabled(false, userDefaults: userDefaults)
      return .requestDeclined
    }

    isRequestingPermission = true
    defer { isRequestingPermission = false }

    let didAuthorize =
      (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) == true
    let refreshedStatus = await refreshAuthorizationStatus()
    guard didAuthorize, refreshedStatus == .authorized else {
      AgentNotificationSettings.setEnabled(
        refreshedStatus == .denied,
        userDefaults: userDefaults
      )
      return refreshedStatus == .denied ? .disabledBySystemPermission : .requestDeclined
    }

    AgentNotificationSettings.setEnabled(true, userDefaults: userDefaults)
    AgentNotificationSettings.setSuppressSystemDeniedLaunchWarning(
      false,
      userDefaults: userDefaults
    )
    return .enabled
  }

  private func notificationContent(
    for event: TerminalAttentionEvent,
    repoRoot: String,
    tab: WorkspaceTerminalTab
  ) -> UNMutableNotificationContent? {
    let context =
      workspaceWindowRegistry?.notificationContext(for: repoRoot)
      ?? WorkspaceTerminalNotificationContext(showsProject: false, showsWorkspace: false)

    guard
      let display = Self.notificationDisplay(
        for: event,
        repoRoot: repoRoot,
        tab: tab,
        context: context
      )
    else {
      return nil
    }

    let content = UNMutableNotificationContent()
    content.title = display.title
    content.subtitle = display.subtitle
    content.body = display.body
    content.sound = .default
    content.userInfo = [
      UserInfoKey.repoRoot: repoRoot,
      UserInfoKey.worktreePath: tab.worktreePath,
      UserInfoKey.terminalTabID: tab.id.uuidString,
    ]
    return content
  }

  nonisolated private static func activationTarget(from userInfo: [AnyHashable: Any])
    -> ActivationTarget?
  {
    guard
      let repoRoot = userInfo[UserInfoKey.repoRoot] as? String,
      let worktreePath = userInfo[UserInfoKey.worktreePath] as? String,
      let terminalTabIDRaw = userInfo[UserInfoKey.terminalTabID] as? String,
      let terminalTabID = UUID(uuidString: terminalTabIDRaw)
    else {
      return nil
    }

    return ActivationTarget(
      repoRoot: repoRoot,
      worktreePath: worktreePath,
      terminalTabID: terminalTabID
    )
  }

  static func notificationDisplay(
    for event: TerminalAttentionEvent,
    repoRoot: String,
    tab: WorkspaceTerminalTab,
    context: WorkspaceTerminalNotificationContext
  ) -> WorkspaceTerminalAttentionNotificationDisplay? {
    let workspaceName = URL(fileURLWithPath: repoRoot).lastPathComponent
    let subtitle = Self.notificationSubtitle(
      projectName: workspaceName,
      worktreeLabel: tab.worktreeLabel,
      context: context
    )

    let title: String
    let body: String

    switch event {
    case .bell:
      title = "Bell"
      body = ""
    case .desktopNotification(let eventTitle, let eventBody):
      let trimmedTitle = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedBody = eventBody.trimmingCharacters(in: .whitespacesAndNewlines)
      title = "Argon"
      body =
        if !trimmedBody.isEmpty {
          trimmedBody
        } else if !trimmedTitle.isEmpty {
          trimmedTitle
        } else {
          "Terminal notification"
        }
    case .commandFinished(let exitCode, let durationNanoseconds):
      if let exitCode {
        if exitCode == 0 {
          title = "Command finished"
        } else {
          title = "Command failed"
        }
      } else {
        title = "Command finished"
      }

      let duration = Duration.nanoseconds(
        Int64(min(durationNanoseconds, UInt64(Int64.max)))
      )
      let formattedDuration = duration.formatted(
        .units(
          allowed: [.hours, .minutes, .seconds, .milliseconds],
          width: .abbreviated,
          fractionalPart: .hide
        ))
      if let exitCode {
        body = "Exited with code \(exitCode) after \(formattedDuration)."
      } else {
        body = "Finished after \(formattedDuration)."
      }
    }

    return WorkspaceTerminalAttentionNotificationDisplay(
      title: title,
      subtitle: subtitle,
      body: body
    )
  }

  private static func notificationSubtitle(
    projectName: String,
    worktreeLabel: String,
    context: WorkspaceTerminalNotificationContext
  ) -> String {
    var components: [String] = []
    if context.showsProject {
      components.append(projectName)
    }
    if context.showsWorkspace {
      components.append(worktreeLabel)
    }
    return components.joined(separator: " • ")
  }
}

@MainActor
protocol WorkspaceUserNotificationCenter: AnyObject {
  var delegate: UNUserNotificationCenterDelegate? { get set }

  func authorizationStatus() async -> UNAuthorizationStatus
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: WorkspaceUserNotificationCenter {
  func authorizationStatus() async -> UNAuthorizationStatus {
    await notificationSettings().authorizationStatus
  }
}

enum AgentNotificationAuthorizationStatus: Equatable {
  case unknown
  case notDetermined
  case authorized
  case denied

  init(_ status: UNAuthorizationStatus) {
    switch status {
    case .authorized, .provisional, .ephemeral:
      self = .authorized
    case .denied:
      self = .denied
    case .notDetermined:
      self = .notDetermined
    @unknown default:
      self = .unknown
    }
  }
}

enum AgentNotificationPreferenceUpdateResult: Equatable {
  case enabled
  case disabled
  case requestDeclined
  case requestInProgress
  case disabledBySystemPermission
}

enum AgentNotificationPermissionRequestSource {
  case agentLaunch
  case settings
}

@MainActor
protocol AgentNotificationPermissionExplaining: AnyObject {
  func shouldRequestAgentNotificationPermission(
    source: AgentNotificationPermissionRequestSource
  ) -> Bool
}

@MainActor
final class AgentNotificationPermissionAlertPresenter: AgentNotificationPermissionExplaining {
  func shouldRequestAgentNotificationPermission(
    source: AgentNotificationPermissionRequestSource
  ) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Enable Agent Notifications?"
    alert.informativeText =
      "Without notifications, Argon cannot tell you when an agent is done or needs your attention. macOS will ask for permission next."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Enable Notifications")
    alert.addButton(withTitle: "Not Now")
    return alert.runModal() == .alertFirstButtonReturn
  }
}

private struct ActivationTarget {
  let repoRoot: String
  let worktreePath: String
  let terminalTabID: UUID
}

struct WorkspaceTerminalAttentionNotificationDisplay: Equatable {
  let title: String
  let subtitle: String
  let body: String
}

struct WorkspaceTerminalNotificationContext: Equatable {
  let showsProject: Bool
  let showsWorkspace: Bool
}
