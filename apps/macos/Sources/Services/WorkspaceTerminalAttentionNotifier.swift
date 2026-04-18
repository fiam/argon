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
  private let notificationCenter: UNUserNotificationCenter
  @ObservationIgnored
  private weak var workspaceWindowRegistry: WorkspaceWindowRegistry?

  init(notificationCenter: UNUserNotificationCenter = .current()) {
    self.notificationCenter = notificationCenter
    super.init()
    self.notificationCenter.delegate = self
  }

  func bind(workspaceWindowRegistry: WorkspaceWindowRegistry) {
    self.workspaceWindowRegistry = workspaceWindowRegistry
    if notificationCenter.delegate !== self {
      notificationCenter.delegate = self
    }
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
    let settings = await notificationCenter.notificationSettings()
    let authorized: Bool
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      authorized = true
    case .notDetermined:
      authorized =
        (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) == true
    default:
      authorized = false
    }
    guard authorized else { return }

    let request = UNNotificationRequest(
      identifier: "argon.workspace-terminal.\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    try? await notificationCenter.add(request)
  }

  private func notificationContent(
    for event: TerminalAttentionEvent,
    repoRoot: String,
    tab: WorkspaceTerminalTab
  ) -> UNMutableNotificationContent? {
    let title: String
    let body: String

    switch event {
    case .bell:
      title = "\(tab.title) needs attention"
      body = "Terminal bell in \(tab.worktreeLabel)."
    case .desktopNotification(let eventTitle, let eventBody):
      title =
        eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "\(tab.title) notification"
        : eventTitle
      body =
        eventBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Message from \(tab.worktreeLabel)."
        : eventBody
    case .commandFinished(let exitCode, let durationNanoseconds):
      if let exitCode {
        if exitCode == 0 {
          title = "\(tab.title) finished command"
        } else {
          title = "\(tab.title) command failed"
        }
      } else {
        title = "\(tab.title) finished command"
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
        body = "Command exited with code \(exitCode) after \(formattedDuration)."
      } else {
        body = "Command finished after \(formattedDuration)."
      }
    }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
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
}

private struct ActivationTarget {
  let repoRoot: String
  let worktreePath: String
  let terminalTabID: UUID
}
