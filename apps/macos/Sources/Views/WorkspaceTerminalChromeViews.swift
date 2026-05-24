import AppKit
import SwiftUI

struct WorkspaceTerminalDeck: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @Environment(SavedAgentProfiles.self) private var savedAgents
  @Environment(ReviewWindowRegistry.self) private var reviewWindowRegistry
  @Environment(WorkspaceTerminalAttentionNotifier.self) private var terminalAttentionNotifier
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    @Bindable var workspaceState = workspaceState

    VStack(spacing: 0) {
      if shouldShowTerminalChrome {
        WorkspaceTerminalChromeBar()
      }

      ZStack {
        if !workspaceState.allTerminalTabs.isEmpty {
          WorkspaceTerminalStage()
        }

        if workspaceState.selectedTerminalTabs.isEmpty {
          WorkspaceTerminalEmptyState(
            onPresentTabCreator: { workspaceState.presentTabCreationSheet() }
          )
        }
      }
      .frame(maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
    }
    .background(Color(nsColor: .textBackgroundColor))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .sheet(
      isPresented: $workspaceState.isPresentingTabCreationSheet,
      content: {
        WorkspaceTabCreationSheet(
          isPresented: $workspaceState.isPresentingTabCreationSheet,
          onNewAgent: {
            workspaceState.presentAgentLaunchSheet()
          },
          onNewShell: {
            workspaceState.requestSandboxedShellLaunch()
          },
          onNewPrivilegedShell: {
            workspaceState.openShellTab(sandboxed: false)
          }
        )
      }
    )
    .sheet(
      isPresented: $workspaceState.isPresentingAgentLaunchSheet,
      onDismiss: {
        workspaceState.dismissAgentLaunchSheet()
      },
      content: {
        let taskContext: WorkspaceAgentTaskContext =
          if workspaceState.isPreparingReviewAgentLaunch {
            .reviewHandoff
          } else if let action = workspaceState.activeFinalizeAction {
            .finalize(action)
          } else {
            .general
          }

        WorkspaceAgentTabSheet(
          isPresented: $workspaceState.isPresentingAgentLaunchSheet,
          taskContext: taskContext,
          onLaunch: { options in
            await launchWorkspaceAgent(options)
          },
          onExternalLaunch: {
            switch taskContext {
            case .reviewHandoff:
              await launchExternalReview()
            case .general, .finalize(_):
              false
            }
          },
          onDidLaunch: {
            if case .reviewHandoff = taskContext {
              workspaceState.activateStagedReviewLaunch()
            }
          }
        )
      }
    )
  }

  private var shouldShowTerminalChrome: Bool {
    !workspaceState.selectedTerminalTabs.isEmpty
      || !workspaceState.restorableAgentSessions(savedProfiles: savedAgents.profiles).isEmpty
  }

  private func launchWorkspaceAgent(_ options: WorkspaceAgentLaunchOptions) async -> Bool {
    do {
      try await workspaceState.launchAgent(using: options)
      let notificationResult = await terminalAttentionNotifier.prepareForAgentTabLaunch()
      if notificationResult == .disabledBySystemPermission
        && AgentNotificationSettings.shouldShowSystemDeniedLaunchWarning()
      {
        presentSystemDeniedNotificationAlert()
      }
      return true
    } catch {
      workspaceState.errorMessage = error.localizedDescription
      return false
    }
  }

  private func presentSystemDeniedNotificationAlert() {
    let alert = NSAlert()
    alert.messageText = "Agent Notifications Disabled"
    alert.informativeText =
      "Without notifications, Argon cannot tell you when an agent is done or needs your attention. Enable Argon in System Settings > Notifications."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "OK")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Don't ask again"

    let response = alert.runModal()
    if alert.suppressionButton?.state == .on {
      AgentNotificationSettings.setSuppressSystemDeniedLaunchWarning(true)
    }
    if response == .alertFirstButtonReturn {
      terminalAttentionNotifier.openSystemNotificationSettings()
    }
  }

  private func launchExternalReview() async -> Bool {
    do {
      let target = try await workspaceState.createReviewTarget(
        launchContext: .externalHandoff,
        changeSummary: workspaceState.selectedReviewSummaryText
      )
      do {
        let prompt = try await Task.detached {
          try ArgonLib.agentPrompt(
            sessionId: target.sessionId,
            repoRoot: target.repoRoot,
            cliCommand: ArgonCLI.cliPath()
          )
        }.value
        copyToPasteboard(prompt)
        reviewWindowRegistry.open(target: target) { target in
          openWindow(value: target)
        }
        return true
      } catch {
        try? await Task.detached {
          try ArgonLib.closeSession(sessionId: target.sessionId, repoRoot: target.repoRoot)
        }.value
        workspaceState.refreshReviewSnapshot(for: target.repoRoot)
        workspaceState.errorMessage =
          "Argon could not build the external agent handoff prompt: \(error.localizedDescription)"
      }
    } catch {
      workspaceState.errorMessage = error.localizedDescription
    }

    return false
  }

  private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

struct WorkspaceTerminalChromeBar: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @Environment(SavedAgentProfiles.self) private var savedAgents

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(workspaceState.selectedTerminalTabs) { tab in
            WorkspaceTerminalTabItem(
              tab: tab,
              agentProfiles: agentProfiles(for: tab),
              isSelected: workspaceState.selectedTerminalTab?.id == tab.id
            ) {
              workspaceState.selectTerminalTab(tab.id)
            } onClose: {
              workspaceState.closeTerminalTab(tab.id)
            } onChangeMode: { sandboxEnabled, yoloMode in
              changeAgentTabMode(
                tab,
                sandboxEnabled: sandboxEnabled,
                yoloMode: yoloMode
              )
            } onChangeProfile: { profile in
              changeAgentTabProfile(tab, profile: profile)
            }
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }

      if !restorableSessions.isEmpty {
        Divider()
          .frame(height: 20)
        WorkspaceAgentSessionRestoreMenu(
          sessions: restorableSessions,
          onRestore: { session in
            workspaceState.restoreAgentSession(session)
          }
        )
        .padding(.horizontal, 8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 2)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.primary.opacity(0.08))
        .frame(height: 1)
    }
  }

  private var restorableSessions: [WorkspaceRestorableAgentSession] {
    Array(workspaceState.restorableAgentSessions(savedProfiles: savedAgents.profiles).prefix(12))
  }

  private func changeAgentTabMode(
    _ tab: WorkspaceTerminalTab,
    sandboxEnabled: Bool? = nil,
    yoloMode: Bool? = nil
  ) {
    let nextSandboxEnabled = sandboxEnabled ?? tab.isSandboxed
    let nextYoloMode = yoloMode ?? tab.yoloMode
    guard nextSandboxEnabled != tab.isSandboxed || nextYoloMode != tab.yoloMode else { return }

    if tab.agentActivityState == .thinking,
      !confirmThinkingAgentRelaunch(
        tab,
        actionDescription: "Changing modes",
        confirmButtonTitle: "Change Mode"
      )
    {
      return
    }

    workspaceState.relaunchAgentTab(
      tab.id,
      sandboxEnabled: nextSandboxEnabled,
      yoloMode: nextYoloMode
    )
  }

  private func changeAgentTabProfile(
    _ tab: WorkspaceTerminalTab,
    profile: SavedAgentProfile
  ) {
    guard
      profile.id != tab.profileID || profile.fullCommand(yolo: false) != tab.baseCommandDescription
    else { return }

    if tab.agentActivityState == .thinking,
      !confirmThinkingAgentRelaunch(
        tab,
        actionDescription: "Changing agent profile",
        confirmButtonTitle: "Change Profile"
      )
    {
      return
    }

    workspaceState.relaunchAgentTab(
      tab.id,
      profile: profile
    )
  }

  private func agentProfiles(for tab: WorkspaceTerminalTab) -> [SavedAgentProfile] {
    guard case .agent = tab.kind else { return [] }
    guard
      let familyID =
        tab.agentFamilyID
        ?? AgentHarnesses.familyID(matchingCommand: tab.baseCommandDescription)
    else { return [] }

    var profiles = savedAgents.profiles.filter { profile in
      profile.isEnabled && profile.familyID == familyID
    }
    if let profileID = tab.profileID,
      let currentProfile = savedAgents.profiles.first(where: { $0.id == profileID }),
      !profiles.contains(where: { $0.id == profileID })
    {
      profiles.insert(currentProfile, at: 0)
    }
    return profiles
  }

  private func confirmThinkingAgentRelaunch(
    _ tab: WorkspaceTerminalTab,
    actionDescription: String,
    confirmButtonTitle: String
  ) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Interrupt Agent?"
    alert.informativeText =
      "\(actionDescription) will close and reopen \(tab.title), interrupting its current task."
    alert.addButton(withTitle: confirmButtonTitle)
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    return alert.runModal() == .alertFirstButtonReturn
  }
}

struct WorkspaceAgentSessionRestoreMenu: View {
  let sessions: [WorkspaceRestorableAgentSession]
  let onRestore: (WorkspaceRestorableAgentSession) -> Void

  var body: some View {
    Menu {
      ForEach(groupedSessions) { group in
        Section(group.title) {
          ForEach(group.sessions) { session in
            Button {
              onRestore(session)
            } label: {
              Label(
                menuTitle(for: session),
                systemImage: session.openStoppedTabID == nil
                  ? "arrow.clockwise" : "arrow.triangle.2.circlepath"
              )
            }
            .help(menuHelp(for: session))
          }
        }
      }
    } label: {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .buttonStyle(.plain)
    .help("Resume a recent conversation")
    .accessibilityIdentifier("workspace-agent-session-restore-menu")
  }

  private var groupedSessions: [WorkspaceAgentSessionRestoreGroup] {
    let calendar = Calendar.current
    var groups: [WorkspaceAgentSessionRestoreGroup] = []
    for session in sessions {
      let title = groupTitle(for: session.startedAt, calendar: calendar)
      if let lastIndex = groups.indices.last, groups[lastIndex].title == title {
        groups[lastIndex].sessions.append(session)
      } else {
        groups.append(WorkspaceAgentSessionRestoreGroup(title: title, sessions: [session]))
      }
    }
    return groups
  }

  private func menuTitle(for session: WorkspaceRestorableAgentSession) -> String {
    var parts = [
      session.profileName,
      session.startedAt.formatted(date: .omitted, time: .shortened),
      String(session.sessionID.prefix(8)),
    ]
    if session.openStoppedTabID != nil {
      parts.append("stopped tab")
    }
    return parts.joined(separator: " - ")
  }

  private func menuHelp(for session: WorkspaceRestorableAgentSession) -> String {
    if session.openStoppedTabID != nil {
      return "Close the stopped tab and resume this conversation."
    }
    return "Resume this conversation."
  }

  private func groupTitle(for date: Date, calendar: Calendar) -> String {
    if calendar.isDateInToday(date) {
      return "Today"
    }
    if calendar.isDateInYesterday(date) {
      return "Yesterday"
    }
    return date.formatted(date: .abbreviated, time: .omitted)
  }
}

struct WorkspaceAgentSessionRestoreGroup: Identifiable {
  let title: String
  var sessions: [WorkspaceRestorableAgentSession]

  var id: String { title }
}

struct WorkspaceTerminalTabItem: View {
  let tab: WorkspaceTerminalTab
  let agentProfiles: [SavedAgentProfile]
  let isSelected: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onChangeMode: (_ sandboxEnabled: Bool?, _ yoloMode: Bool?) -> Void
  let onChangeProfile: (SavedAgentProfile) -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onSelect) {
        HStack(spacing: 5) {
          if case .agent = tab.kind {
            agentIcon
          } else {
            Image(systemName: tab.isSandboxed ? "terminal" : "lock.open")
              .font(.system(size: 11, weight: .medium))
          }

          ZStack {
            activityIndicator
              .opacity(tab.isShowingBellIndicator ? 0 : 1)

            Image(systemName: "bell.fill")
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(Color.orange)
              .opacity(tab.isShowingBellIndicator ? 1 : 0)
          }
          .frame(width: 10, height: 10)
          .animation(.easeInOut(duration: 0.15), value: tab.isShowingBellIndicator)

          Text(tab.title)
            .font(.caption)
            .fontWeight(isSelected ? .medium : .regular)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .accessibilityIdentifier(accessibilityIdentifier)
      .buttonStyle(.plain)
      .help(tabHelp)

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.tertiary)
          .frame(width: 12, height: 12)
      }
      .buttonStyle(.plain)
      .opacity(isSelected || isHovering ? 0.9 : 0.0)
      .help("Close \(tab.title)")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(
          isSelected
            ? Color.accentColor.opacity(0.16)
            : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .contextMenu {
      if case .agent = tab.kind {
        if !agentProfiles.isEmpty {
          Menu {
            ForEach(agentProfiles) { profile in
              Button {
                onChangeProfile(profile)
              } label: {
                Label(
                  profile.name,
                  systemImage: profile.id == tab.profileID ? "checkmark" : "slider.horizontal.3"
                )
              }
            }
          } label: {
            Label("Agent Profile", systemImage: "slider.horizontal.3")
          }

          Divider()
        }

        if !tab.yoloFlag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Button {
            onChangeMode(nil, !tab.yoloMode)
          } label: {
            Label(
              tab.yoloMode ? "Disable Yolo Mode" : "Enable Yolo Mode",
              systemImage: tab.yoloMode ? "bolt.slash" : "bolt"
            )
          }
        }

        Button {
          onChangeMode(!tab.isSandboxed, nil)
        } label: {
          Label(
            tab.isSandboxed ? "Disable Sandbox" : "Enable Sandbox",
            systemImage: tab.isSandboxed ? "lock.open" : "lock"
          )
        }
      }
    }
    .onHover { hovering in
      isHovering = hovering
    }
  }

  @ViewBuilder
  private var agentIcon: some View {
    if isThinking {
      TimelineView(.animation) { context in
        AgentIconView(icon: resolvedAgentTabIconName, size: 12)
          .foregroundStyle(.primary)
          .rotationEffect(thinkingRotation(at: context.date))
      }
    } else {
      AgentIconView(icon: resolvedAgentTabIconName, size: 12)
        .foregroundStyle(.primary)
    }
  }

  private var tabHelp: String {
    let activity =
      if case .agent = tab.kind {
        "\nAgent state: \(agentActivityHelpLabel)"
      } else {
        ""
      }

    return "\(tab.title) in \(tab.worktreeLabel)\n\(tab.commandDescription)\(activity)"
  }

  @ViewBuilder
  private var activityIndicator: some View {
    if tab.agentActivityState == .waitingForHuman, case .agent = tab.kind {
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color.orange)
        .frame(width: 10, height: 10)
    } else {
      Circle()
        .fill(attentionIndicatorColor)
        .frame(width: 6, height: 6)
        .frame(width: 10, height: 10)
    }
  }

  private var attentionIndicatorColor: Color {
    if tab.hasAttention {
      return .orange
    }
    return tab.isRunning ? Color(nsColor: .systemGreen) : .secondary
  }

  private var isThinking: Bool {
    tab.agentActivityState == .thinking
  }

  private var agentActivityHelpLabel: String {
    tab.agentActivityState.displayLabel
  }

  private func thinkingRotation(at date: Date) -> Angle {
    let period = 2.0
    let progress =
      date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
      / period
    return .degrees(progress * 360)
  }

  private var resolvedAgentTabIconName: String {
    guard case .agent(_, let icon) = tab.kind else { return "agent" }
    switch icon {
    case "claude", "codex", "antigravity":
      return icon
    default:
      return "agent"
    }
  }

  private var accessibilityIdentifier: String {
    let sanitizedTitle = tab.title
      .lowercased()
      .map { character -> Character in
        if character.isLetter || character.isNumber {
          return character
        }
        return "-"
      }
      .reduce(into: "") { partial, character in
        if character == "-", partial.last == "-" {
          return
        }
        partial.append(character)
      }
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "workspace-terminal-tab-\(sanitizedTitle)"
  }
}

struct WorkspaceStatusPill: View {
  let label: String
  let tint: Color

  var body: some View {
    Text(label)
      .font(.system(size: 10, weight: .semibold, design: .monospaced))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(tint.opacity(0.1), in: Capsule())
      .foregroundStyle(tint)
  }
}

struct WorkspaceReviewStatusPill: View {
  let status: SessionStatus

  var body: some View {
    WorkspaceStatusPill(label: label, tint: tint)
  }

  private var label: String {
    switch status {
    case .awaitingReviewer:
      "awaiting review"
    case .awaitingAgent:
      "awaiting agent"
    case .approved:
      "approved"
    case .closed:
      "closed"
    }
  }

  private var tint: Color {
    switch status {
    case .awaitingReviewer:
      .orange
    case .awaitingAgent:
      .blue
    case .approved:
      .green
    case .closed:
      .secondary
    }
  }
}

struct WorkspaceDecisionPill: View {
  let outcome: ReviewOutcome

  var body: some View {
    WorkspaceStatusPill(label: label, tint: tint)
  }

  private var label: String {
    switch outcome {
    case .approved:
      "approved"
    case .changesRequested:
      "changes requested"
    case .commented:
      "commented"
    }
  }

  private var tint: Color {
    switch outcome {
    case .approved:
      .green
    case .changesRequested:
      .orange
    case .commented:
      .blue
    }
  }
}
