import AppKit
import SwiftUI

struct WorkspaceTerminalStage: View {
  @Environment(CommandContext.self) private var commandContext
  @Environment(WorkspaceState.self) private var workspaceState
  @Environment(WorkspaceTerminalAttentionNotifier.self) private var terminalAttentionNotifier
  @AppStorage("terminalFontSize") private var terminalFontSizeFallback = 12.0
  @AppStorage(GhosttyConfigurationSettings.storageKey) private var ghosttyConfigurationText = ""
  @AppStorage(WorkspaceFinishedTerminalBehavior.storageKey) private var finishedTerminalBehavior =
    WorkspaceFinishedTerminalBehavior.autoClose.rawValue

  var body: some View {
    ZStack {
      ForEach(workspaceState.allTerminalTabs) { tab in
        let isSelected = workspaceState.selectedTerminalTab?.id == tab.id
        GhosttyTerminalView(
          controller: tab,
          launch: tab.launch,
          terminalID: tab.id,
          terminalFontSize: effectiveTerminalFontSize,
          ghosttyConfigurationText: ghosttyConfigurationText,
          isRenderVisible: isSelected,
          waitAfterCommand: waitAfterCommand(for: tab),
          onProcessExit: {
            workspaceState.handleTerminalExit(
              tab.id,
              exitBehavior: selectedFinishedTerminalBehavior
            )
          },
          onAttention: { event in
            guard !tab.shouldSuppressAttention() else { return }

            if case .desktopNotification = event {
              workspaceState.markAgentWaitingForHuman(tab.id)
            }

            switch WorkspaceTerminalAttentionRouting.disposition(
              for: event,
              isVisibleTerminal: isVisibleTerminal(tabID: tab.id)
            ) {
            case .localBell:
              workspaceState.flashTerminalBell(tab.id)
              NSSound.beep()
            case .notifyAndMarkAttention:
              workspaceState.markTerminalNeedsAttention(tab.id)
              terminalAttentionNotifier.postAttentionNotification(
                event: event,
                repoRoot: workspaceState.target.repoRoot,
                tab: tab
              )
            }
          },
          onTitleChange: { titleChange in
            workspaceState.recordTerminalTitleChange(titleChange.title, for: tab.id)
          },
          focusRequestID: isSelected ? workspaceState.selectedTerminalFocusRequestID : nil
        )
        .id(tab.terminalViewIdentity)
        .task(id: tab.terminalViewIdentity) {
          await monitorTerminalAttach(
            tabID: tab.id,
            exitBehavior: selectedFinishedTerminalBehavior
          )
        }
        .zIndex(isSelected ? 1 : 0)
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected)
        .accessibilityHidden(!isSelected)
      }

      if let selectedTerminalTab,
        shouldShowExitedShellOverlay(for: selectedTerminalTab)
      {
        WorkspaceExitedShellOverlay(
          tabTitle: selectedTerminalTab.title,
          onClose: { workspaceState.closeTerminalTab(selectedTerminalTab.id) },
          onNewShell: { workspaceState.requestSandboxedShellLaunch() }
        )
        .padding(24)
        .zIndex(2)
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onChange(of: visibleAttentionTabID, initial: true) { oldTabID, newTabID in
      if let oldTabID, oldTabID != newTabID {
        workspaceState.cancelTerminalAttentionVisibilityDwell(for: oldTabID)
      }
      if let newTabID {
        workspaceState.beginTerminalAttentionVisibilityDwell(for: newTabID)
      }
    }
  }

  private var selectedFinishedTerminalBehavior: WorkspaceFinishedTerminalBehavior {
    WorkspaceFinishedTerminalBehavior(rawValue: finishedTerminalBehavior) ?? .autoClose
  }

  private func isVisibleTerminal(tabID: UUID) -> Bool {
    commandContext.activeWorkspaceState === workspaceState
      && workspaceState.selectedTerminalTab?.id == tabID
  }

  private var effectiveTerminalFontSize: Double {
    GhosttyConfigurationSettings.fontSize(from: ghosttyConfigurationText)
      ?? terminalFontSizeFallback
  }

  private var selectedTerminalTab: WorkspaceTerminalTab? {
    workspaceState.selectedTerminalTab
  }

  private var visibleAttentionTabID: UUID? {
    guard let selectedTerminalTab,
      selectedTerminalTab.hasAttention,
      isVisibleTerminal(tabID: selectedTerminalTab.id)
    else {
      return nil
    }
    return selectedTerminalTab.id
  }

  private func waitAfterCommand(for tab: WorkspaceTerminalTab) -> Bool {
    if tab.terminalSession != nil {
      return false
    }
    return selectedFinishedTerminalBehavior == .keepOpen
  }

  @MainActor
  private func monitorTerminalAttach(
    tabID: UUID,
    exitBehavior: WorkspaceFinishedTerminalBehavior
  ) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }

      guard GhosttyTerminalView.processExited(for: tabID) else { continue }
      let recovered = workspaceState.recoverPersistentTerminalAttachIfExited(
        tabID,
        processExited: true
      )
      if !recovered {
        workspaceState.handleTerminalExit(tabID, exitBehavior: exitBehavior)
      }
      return
    }
  }

  private func shouldShowExitedShellOverlay(for tab: WorkspaceTerminalTab) -> Bool {
    guard case .shell = tab.kind else { return false }
    return !tab.isRunning && selectedFinishedTerminalBehavior == .keepOpen
  }
}

struct WorkspaceExitedShellOverlay: View {
  let tabTitle: String
  let onClose: () -> Void
  let onNewShell: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.orange.opacity(0.14))
        .frame(width: 64, height: 64)
        .overlay {
          Image(systemName: "terminal.fill")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.orange)
        }

      VStack(spacing: 8) {
        Text("\(tabTitle) exited")
          .font(.title3.weight(.semibold))
        Text("Keep this transcript open, close the tab, or start a fresh shell.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 360)
      }

      HStack(spacing: 12) {
        Button("Close Tab", action: onClose)
          .buttonStyle(.borderedProminent)

        Button("New Shell Tab", action: onNewShell)
          .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }
}

struct WorkspaceTerminalEmptyState: View {
  let onPresentTabCreator: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button {
      onPresentTabCreator()
    } label: {
      VStack(spacing: 16) {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color.accentColor.opacity(0.12))
          .frame(width: 64, height: 64)
          .overlay {
            Image(systemName: "rectangle.stack.badge.plus")
              .font(.system(size: 24, weight: .medium))
              .foregroundStyle(Color.accentColor)
          }

        VStack(spacing: 8) {
          Text("No Tabs Yet")
            .font(.title3.weight(.semibold))
          Text("Open an agent, shell, or privileged shell in this worktree.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
          Text("Open tab")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.top, 4)
        }
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 32)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(isHovering ? Color.accentColor.opacity(0.05) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(isHovering ? Color.accentColor.opacity(0.18) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.vertical, 32)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}

struct WorkspaceTabCreationSheet: View {
  @Binding var isPresented: Bool
  let onNewAgent: () -> Void
  let onNewShell: () -> Void
  let onNewPrivilegedShell: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "rectangle.stack.badge.plus")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("Create a New Tab")
            .font(.title2.weight(.semibold))
          Text("Choose what to open in this worktree.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      VStack(spacing: 10) {
        WorkspaceTabTypeCard(
          icon: "sparkles.rectangle.stack",
          title: "Agent Tab",
          description: "Launch a saved coding agent in yolo mode.",
          shortcut: "⌘T",
          action: { select(onNewAgent) }
        )
        .keyboardShortcut("t", modifiers: .command)

        WorkspaceTabTypeCard(
          icon: "terminal",
          title: "Shell Tab",
          description:
            "Open a sandboxed shell rooted in the selected worktree.",
          shortcut: "⇧⌘T",
          action: { select(onNewShell) }
        )
        .keyboardShortcut("t", modifiers: [.command, .shift])

        WorkspaceTabTypeCard(
          icon: "lock.open",
          title: "Privileged Shell Tab",
          description:
            "Open an unsandboxed shell with your full user permissions.",
          shortcut: "⌥⇧⌘T",
          action: { select(onNewPrivilegedShell) }
        )
        .keyboardShortcut("t", modifiers: [.command, .shift, .option])
      }

      HStack {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
      }
    }
    .padding(24)
    .frame(width: 560)
  }

  private func select(_ action: @escaping () -> Void) {
    isPresented = false
    DispatchQueue.main.async {
      action()
    }
  }
}

struct WorkspaceTabTypeCard: View {
  let icon: String
  let title: String
  let description: String
  let shortcut: String
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: icon)
          .font(.title3)
          .foregroundStyle(Color.accentColor)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(title)
              .font(.headline)
            Text(shortcut)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
          }

          Text(description)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 14)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(
            isHovering
              ? Color.accentColor.opacity(0.08)
              : Color(nsColor: .controlBackgroundColor).opacity(0.7)
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isHovering ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}
