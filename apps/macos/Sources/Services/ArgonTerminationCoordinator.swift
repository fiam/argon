import AppKit

@MainActor
final class ArgonTerminationCoordinator {
  static let shared = ArgonTerminationCoordinator()

  private weak var workspaceWindowRegistry: WorkspaceWindowRegistry?

  private init() {}

  func register(workspaceWindowRegistry: WorkspaceWindowRegistry) {
    self.workspaceWindowRegistry = workspaceWindowRegistry
  }

  func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
    guard let workspaceWindowRegistry else { return .terminateNow }

    let quitSummary = workspaceWindowRegistry.quitAgentSummary
    guard quitSummary.needsPrompt else {
      workspaceWindowRegistry.prepareForAppTermination(keepRunningAgentsAlive: false)
      return .terminateNow
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = messageText(for: quitSummary)
    alert.informativeText = informativeText(for: quitSummary)
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    if quitSummary.keepRunningCount > 0 {
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title =
        quitSummary.keepRunningCount == 1
        ? "Stop this agent instead"
        : "Stop these agents instead"
      alert.suppressionButton?.state = .off
    }

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return .terminateCancel }

    let shouldStopRunningAgents =
      quitSummary.keepRunningCount > 0 && alert.suppressionButton?.state == .on
    if shouldStopRunningAgents {
      workspaceWindowRegistry.closeThinkingAgentTabs()
    }
    workspaceWindowRegistry.prepareForAppTermination(
      keepRunningAgentsAlive: workspaceWindowRegistry.quitAgentSummary.keepRunningCount > 0
    )
    return .terminateNow
  }

  private func messageText(for summary: WorkspaceQuitAgentSummary) -> String {
    if summary.thinkingCount > 0 {
      return summary.warningCount == 1
        ? "Agent Is Still Thinking"
        : "Agents Are Still Thinking"
    }

    return summary.warningCount == 1
      ? "Agent Is Still Running"
      : "Agents Are Still Running"
  }

  private func informativeText(for summary: WorkspaceQuitAgentSummary) -> String {
    if summary.keepRunningCount == 0 {
      return summary.warningCount == 1
        ? "Quitting will stop this thinking agent. Argon will try to resume the session on the next launch."
        : "Quitting will stop these \(summary.warningCount) thinking agents. Argon will try to resume the sessions on the next launch."
    }

    let keepRunningText =
      summary.keepRunningCount == 1
      ? "Argon will keep this thinking agent running after quitting and reconnect on the next launch."
      : "Argon will keep \(summary.keepRunningCount) thinking agents running after quitting and reconnect on the next launch."

    let fallbackText =
      summary.keepRunningCount == 1
      ? "If reconnecting fails, Argon will resume the preserved session."
      : "If reconnecting fails, Argon will resume the preserved sessions."
    let stoppedCount = summary.warningCount - summary.keepRunningCount
    guard stoppedCount > 0 else {
      return "\(keepRunningText) \(fallbackText)"
    }

    let stoppedText =
      stoppedCount == 1
      ? "One other thinking agent will stop."
      : "\(stoppedCount) other thinking agents will stop."
    return "\(keepRunningText) \(stoppedText) \(fallbackText)"
  }
}

final class ArgonApplicationDelegate: NSObject, NSApplicationDelegate {
  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    ArgonTerminationCoordinator.shared.applicationShouldTerminate(sender)
  }
}
