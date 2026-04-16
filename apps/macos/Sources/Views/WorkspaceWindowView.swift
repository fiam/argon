import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceWindowView: View {
  @Environment(CommandContext.self) private var commandContext
  @Environment(WorkspaceWindowRegistry.self) private var workspaceWindowRegistry
  let target: WorkspaceTarget
  @State private var workspaceState: WorkspaceState

  init(target: WorkspaceTarget) {
    self.target = target
    self._workspaceState = State(initialValue: WorkspaceState(target: target))
  }

  var body: some View {
    WorkspaceContentView()
      .frame(
        minWidth: 1180,
        idealWidth: 1180,
        maxWidth: .infinity,
        minHeight: 700,
        idealHeight: 700,
        maxHeight: .infinity,
        alignment: .topLeading
      )
      .environment(workspaceState)
      .focusedValue(\.workspaceState, workspaceState)
      .background {
        WindowKeyObserver(
          onBecomeKey: { commandContext.activate(workspaceState: workspaceState) },
          onResignKey: { commandContext.clear(workspaceState: workspaceState) },
          onWindowChange: { window in
            guard let window else {
              workspaceWindowRegistry.unregister(window: nil, repoRoot: target.repoRoot)
              return
            }
            workspaceWindowRegistry.register(
              window: window,
              workspaceState: workspaceState,
              repoRoot: target.repoRoot
            )
          }
        )
      }
      .navigationTitle("Argon \u{2014} \(workspaceState.repoName)")
      .onAppear {
        if workspaceState.worktrees.isEmpty && !workspaceState.isLoading {
          workspaceState.load()
        }
      }
  }
}

private struct WorkspaceContentView: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @State private var showInspector = true

  var body: some View {
    NavigationSplitView {
      WorkspaceSidebar()
        .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 290)
    } detail: {
      WorkspaceCenterPane()
        .inspector(isPresented: $showInspector) {
          WorkspaceInspectorPane()
            .inspectorColumnWidth(min: 300, ideal: 320, max: 360)
        }
    }
    .navigationSplitViewStyle(.balanced)
    .background(WorkspaceBackground())
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        if let errorMessage = workspaceState.errorMessage {
          WorkspaceBanner(
            message: errorMessage,
            symbolName: "exclamationmark.triangle.fill",
            tint: .red
          ) {
            workspaceState.errorMessage = nil
          }
        }

        if let launchWarningMessage = workspaceState.launchWarningMessage {
          WorkspaceBanner(
            message: launchWarningMessage,
            symbolName: "arrow.turn.up.left.circle.fill",
            tint: .orange
          ) {
            workspaceState.launchWarningMessage = nil
          }
        }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if workspaceState.selectedWorktree != nil {
          WorkspaceTitleBarActionCluster(
            onNewAgent: { workspaceState.presentAgentLaunchSheet() },
            onPresentTabCreator: { workspaceState.presentTabCreationSheet() },
            onNewShell: { workspaceState.openShellTab() },
            onNewPrivilegedShell: { workspaceState.openShellTab(sandboxed: false) }
          )
        }
      }
    }
  }
}

private struct WorkspaceSidebar: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @State private var showNewWorktreeSheet = false

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        if workspaceState.worktrees.isEmpty && workspaceState.isLoading {
          ProgressView("Loading worktrees...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspaceState.worktrees.isEmpty {
          ContentUnavailableView(
            "No Worktrees",
            systemImage: "square.stack.3d.up.slash",
            description: Text("Open a Git repository to populate the workspace.")
          )
        } else {
          ScrollView {
            LazyVStack(spacing: 10) {
              ForEach(workspaceState.worktrees) { worktree in
                WorkspaceSidebarRow(
                  worktree: worktree,
                  repoRoot: workspaceState.target.repoRoot,
                  isSelected: workspaceState.selectedWorktree?.path == worktree.path
                ) {
                  workspaceState.selectWorktree(path: worktree.path)
                }
              }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 14)
          }
          .scrollIndicators(.hidden)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .navigationTitle("Worktrees")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showNewWorktreeSheet = true
        } label: {
          Image(systemName: "plus")
        }
        .help("Create a new worktree")
      }
    }
    .sheet(isPresented: $showNewWorktreeSheet) {
      WorkspaceNewWorktreeSheet(isPresented: $showNewWorktreeSheet)
    }
    .background(
      LinearGradient(
        colors: [
          Color(nsColor: .controlBackgroundColor).opacity(0.92),
          Color(nsColor: .windowBackgroundColor).opacity(0.96),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(width: 0.5)
    }
    .clipped()
  }
}

private struct WorkspaceSidebarRow: View {
  @Environment(WorkspaceState.self) private var workspaceState
  let worktree: DiscoveredWorktree
  let repoRoot: String
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text(worktree.branchName ?? "Detached HEAD")
            .font(.system(.body, design: .monospaced))
            .fontWeight(.medium)
            .lineLimit(1)

          if worktree.isBaseWorktree {
            WorkspaceBadge(label: "Base", tint: .blue)
          } else if worktree.isDetached {
            WorkspaceBadge(label: "Detached", tint: .orange)
          }

          Spacer(minLength: 0)
        }

        HStack(spacing: 6) {
          Image(systemName: "folder")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(shortPath)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        HStack(spacing: 6) {
          if let reviewSnapshot {
            WorkspaceReviewStatusPill(status: reviewSnapshot.status)
          }

          if hasConflicts {
            WorkspaceStatusPill(label: "conflicts", tint: .orange)
          }

          if activeAgentCount > 0 {
            WorkspaceStatusPill(
              label: activeAgentCount == 1 ? "1 agent" : "\(activeAgentCount) agents",
              tint: .blue
            )
          }

          if summary.hasChanges {
            WorkspaceStatusPill(
              label: summary.fileCount == 1 ? "1 file" : "\(summary.fileCount) files",
              tint: Color(nsColor: .systemGreen)
            )
          } else {
            WorkspaceStatusPill(
              label: "clean",
              tint: .secondary
            )
          }

          Spacer(minLength: 0)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(
            isSelected
              ? Color.accentColor.opacity(0.16)
              : Color(nsColor: .windowBackgroundColor).opacity(0.76)
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private var shortPath: String {
    let normalizedRepoRoot = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
    let normalizedPath = URL(fileURLWithPath: worktree.path).standardizedFileURL.path

    if normalizedPath == normalizedRepoRoot {
      return "."
    }

    if normalizedPath.hasPrefix(normalizedRepoRoot + "/") {
      return String(normalizedPath.dropFirst(normalizedRepoRoot.count + 1))
    }

    return normalizedPath
  }

  private var summary: WorktreeDiffSummary {
    workspaceState.summary(for: worktree.path)
  }

  private var reviewSnapshot: WorkspaceReviewSnapshot? {
    workspaceState.reviewSnapshot(for: worktree.path)
  }

  private var hasConflicts: Bool {
    workspaceState.hasConflicts(for: worktree.path)
  }

  private var activeAgentCount: Int {
    workspaceState.activeAgentCount(for: worktree.path)
  }
}

private struct WorkspaceCenterPane: View {
  @Environment(WorkspaceState.self) private var workspaceState

  var body: some View {
    GeometryReader { proxy in
      Group {
        if workspaceState.selectedWorktree != nil {
          WorkspaceTerminalDeck()
            .padding(.bottom, 20)
        } else if workspaceState.isLoading {
          ProgressView("Loading workspace...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView(
            "Select a Worktree",
            systemImage: "square.stack.3d.up",
            description: Text("Choose a worktree from the sidebar to inspect it.")
          )
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
  }
}

private struct WorkspaceTitleBarActionCluster: View {
  let onNewAgent: () -> Void
  let onPresentTabCreator: () -> Void
  let onNewShell: () -> Void
  let onNewPrivilegedShell: () -> Void

  var body: some View {
    ControlGroup {
      Button(action: onNewAgent) {
        Image(systemName: "sparkles.rectangle.stack")
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 26, height: 26)
      }
      .help("New agent tab")

      Button(action: onPresentTabCreator) {
        Image(systemName: "plus")
          .font(.system(size: 14, weight: .bold))
          .frame(width: 28, height: 28)
      }
      .help("Create a tab")

      Button(action: onNewShell) {
        Image(systemName: "terminal")
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 26, height: 26)
      }
      .help("New shell tab")
    }
    .controlGroupStyle(.navigation)
    .controlSize(.regular)
    .fixedSize()
  }
}

private struct WorkspaceChangedFilesPane: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @State private var selectedFileID: String?

  var body: some View {
    WorkspaceSurface(fillColor: Color(nsColor: .textBackgroundColor).opacity(0.98)) {
      if workspaceState.isLoadingSelectionDetails {
        VStack {
          ProgressView()
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        FileTreePanel(
          files: workspaceState.selectedFiles,
          emptyTitle: "No Changed Files",
          emptySystemImage: "checkmark.circle",
          emptyDescription: "This worktree is clean.",
          selectedFileID: selectedFileID,
          focusFilterRequest: false,
          onConsumeFocusFilterRequest: nil,
          onSelectFile: { file in
            selectedFileID = file.id
          },
          onOpenFile: { file in
            openFileInPreferredEditor(file)
          }
        )
        .id(workspaceState.normalizedSelectedWorktreePath ?? "workspace-file-tree")
      }
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .onChange(of: workspaceState.selectedWorktreePath) { _, _ in
      selectedFileID = nil
    }
  }

  private func openFileInPreferredEditor(_ file: FileDiff) {
    guard let worktree = workspaceState.selectedWorktree else { return }

    let editors = EditorLocator.discoverInstalledEditors()
    guard let editor = EditorPreferenceStore.preferredEditor(for: worktree.path, among: editors)
    else {
      workspaceState.errorMessage = "No supported editor found for this worktree."
      return
    }

    guard let relativePath = file.preferredOpenPath else {
      workspaceState.errorMessage = "This file cannot be opened from the current diff."
      return
    }

    let fileURL = URL(fileURLWithPath: worktree.path).appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      workspaceState.errorMessage = "Cannot open \(relativePath) because it no longer exists."
      return
    }

    Task {
      do {
        try await EditorLocator.open(editor, urls: [fileURL])
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }
}

private struct WorkspaceTerminalDeck: View {
  @Environment(WorkspaceState.self) private var workspaceState

  var body: some View {
    @Bindable var workspaceState = workspaceState

    VStack(spacing: 0) {
      if workspaceState.selectedTerminalTabs.isEmpty {
        WorkspaceTerminalEmptyState(
          onPresentTabCreator: { workspaceState.presentTabCreationSheet() }
        )
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
      } else {
        WorkspaceTerminalChromeBar()
        WorkspaceTerminalStage()
          .frame(maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
      }
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
            workspaceState.openShellTab()
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
        WorkspaceAgentTabSheet(
          isPresented: $workspaceState.isPresentingAgentLaunchSheet,
          allowsCustomCommand: workspaceState.isPreparingReviewAgentLaunch,
          isReviewHandoffRequest: workspaceState.isPreparingReviewAgentLaunch,
          onLaunch: { options in
            do {
              try await workspaceState.launchAgent(using: options)
              return true
            } catch {
              workspaceState.errorMessage = error.localizedDescription
              return false
            }
          },
          onDidLaunch: {
            workspaceState.activateStagedReviewLaunch()
          }
        )
      }
    )
  }
}

private struct WorkspaceTerminalChromeBar: View {
  @Environment(WorkspaceState.self) private var workspaceState

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        ForEach(workspaceState.selectedTerminalTabs) { tab in
          WorkspaceTerminalTabItem(
            tab: tab,
            isSelected: workspaceState.selectedTerminalTab?.id == tab.id
          ) {
            workspaceState.selectTerminalTab(tab.id)
          } onClose: {
            workspaceState.closeTerminalTab(tab.id)
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
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
}

private struct WorkspaceTerminalTabItem: View {
  let tab: WorkspaceTerminalTab
  let isSelected: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onSelect) {
        HStack(spacing: 5) {
          if case .agent(_, let icon) = tab.kind {
            AgentIconView(icon: icon, size: 12)
          } else {
            Image(systemName: tab.isSandboxed ? "lock.shield" : "terminal")
              .font(.system(size: 11, weight: .medium))
          }

          Circle()
            .fill(tab.isRunning ? Color(nsColor: .systemGreen) : Color.secondary)
            .frame(width: 6, height: 6)

          Text(tab.title)
            .font(.caption)
            .fontWeight(isSelected ? .medium : .regular)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
      }
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
    .onHover { hovering in
      isHovering = hovering
    }
  }

  private var tabHelp: String {
    "\(tab.title) in \(tab.worktreeLabel)\n\(tab.commandDescription)"
  }
}

private struct WorkspaceStatusPill: View {
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

private struct WorkspaceReviewStatusPill: View {
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

private struct WorkspaceDecisionPill: View {
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

private struct WorkspaceTerminalStage: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @AppStorage("terminalFontSize") private var terminalFontSize = 12.0
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
          terminalFontSize: terminalFontSize,
          waitAfterCommand: waitAfterCommand(for: tab),
          onProcessExit: {
            workspaceState.handleTerminalExit(
              tab.id,
              exitBehavior: selectedFinishedTerminalBehavior
            )
          },
          focusRequestID: isSelected ? workspaceState.selectedTerminalFocusRequestID : nil
        )
        .id(tab.id)
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
          onNewShell: { workspaceState.openShellTab() }
        )
        .padding(24)
        .zIndex(2)
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var selectedFinishedTerminalBehavior: WorkspaceFinishedTerminalBehavior {
    WorkspaceFinishedTerminalBehavior(rawValue: finishedTerminalBehavior) ?? .autoClose
  }

  private var selectedTerminalTab: WorkspaceTerminalTab? {
    workspaceState.selectedTerminalTab
  }

  private func waitAfterCommand(for tab: WorkspaceTerminalTab) -> Bool {
    selectedFinishedTerminalBehavior == .keepOpen
  }

  private func shouldShowExitedShellOverlay(for tab: WorkspaceTerminalTab) -> Bool {
    guard case .shell = tab.kind else { return false }
    return !tab.isRunning && selectedFinishedTerminalBehavior == .keepOpen
  }
}

private struct WorkspaceExitedShellOverlay: View {
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

private struct WorkspaceTerminalEmptyState: View {
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

private struct WorkspaceTabCreationSheet: View {
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
          description:
            "Launch a saved coding agent with sandbox and approval options.",
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

private struct WorkspaceTabTypeCard: View {
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

private struct WorkspaceAgentTabSheet: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @Environment(SavedAgentProfiles.self) private var savedAgents
  @Environment(AgentAvailability.self) private var agentAvailability
  @Binding var isPresented: Bool
  let allowsCustomCommand: Bool
  let isReviewHandoffRequest: Bool
  let onLaunch: @MainActor (WorkspaceAgentLaunchOptions) async -> Bool
  let onDidLaunch: @MainActor () -> Void

  @State private var selectedAgentId: String?
  @State private var yoloMode = true
  @State private var sandboxEnabled = true
  @State private var customCommand = ""
  @State private var customName = ""
  @State private var useCustom = false
  @State private var isLaunching = false
  @State private var showSandboxHelp = false
  @State private var sandboxHelp: SandboxHelpData?
  @State private var sandboxHelpError: String?
  @State private var sandboxHelpLoading = false

  private var selectedSavedAgent: SavedAgentProfile? {
    guard let selectedAgentId else { return nil }
    return savedAgents.profiles.first { $0.id == selectedAgentId }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "sparkles.rectangle.stack")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text(sheetTitle)
            .font(.title2.weight(.semibold))
          Text(sheetSubtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("Agent")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
          if agentAvailability.hasPendingCommands {
            ProgressView()
              .controlSize(.small)
          }
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: AgentPickerLayout.gridMinimumWidth))], spacing: 8
        ) {
          ForEach(savedAgents.profiles) { profile in
            savedAgentCard(for: profile)
          }

          if allowsCustomCommand {
            CustomAgentPickerCard(isSelected: useCustom, accentColor: .accentColor) {
              useCustom = true
              selectedAgentId = nil
              yoloMode = false
            }
          }
        }
      }

      if allowsCustomCommand && useCustom {
        VStack(alignment: .leading, spacing: 8) {
          TextField("Tab name", text: $customName)
            .textFieldStyle(.roundedBorder)
          TextField("Command", text: $customCommand)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Toggle(isOn: $sandboxEnabled) {
          Text("Sandboxed")
            .font(.callout)
        }
        .toggleStyle(.checkbox)

        Button("Configuration") {
          presentSandboxHelp()
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.leading, 22)
        .popover(isPresented: $showSandboxHelp, arrowEdge: .bottom) {
          SandboxHelpPopover(
            help: sandboxHelp,
            errorMessage: sandboxHelpError,
            isLoading: sandboxHelpLoading
          )
        }
      }

      if let selectedSavedAgent, !selectedSavedAgent.yoloFlag.isEmpty {
        Toggle(isOn: $yoloMode) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Auto-approve mode")
              .font(.callout)
            Text(yoloSubtitle(for: selectedSavedAgent.yoloFlag))
              .font(.caption)
              .foregroundStyle(yoloSubtitleColor)
          }
        }
        .toggleStyle(.checkbox)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)
        .disabled(isLaunching)

        Button("Launch") {
          launch()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canLaunch)
      }
    }
    .padding(24)
    .frame(width: 520)
    .onAppear {
      agentAvailability.refresh(for: savedAgents.profiles)
      syncSelectedAgent()
    }
    .onChange(of: savedAgents.profiles) { _, _ in
      agentAvailability.refresh(for: savedAgents.profiles)
      syncSelectedAgent()
    }
    .onChange(of: agentAvailability.revision) { _, _ in
      syncSelectedAgent()
    }
    .onChange(of: allowsCustomCommand) { _, allowsCustomCommand in
      if !allowsCustomCommand {
        useCustom = false
      }
    }
  }

  private var canLaunch: Bool {
    guard !isLaunching else { return false }
    if allowsCustomCommand && useCustom {
      return !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let selectedSavedAgent else { return false }
    return agentAvailability.status(for: selectedSavedAgent) == .available
  }

  private var sheetTitle: String {
    isReviewHandoffRequest ? "Launch Review Agent" : "New Agent Tab"
  }

  private var sheetSubtitle: String {
    if isReviewHandoffRequest {
      return "Launch an agent to handle review comments for this worktree."
    }

    return allowsCustomCommand
      ? "Launch a saved agent or custom command in the selected worktree."
      : "Launch a saved agent in the selected worktree."
  }

  private func launch() {
    guard let launchOptions else { return }

    isLaunching = true
    Task { @MainActor in
      let didLaunch = await onLaunch(launchOptions)
      isLaunching = false
      guard didLaunch else { return }
      isPresented = false
      DispatchQueue.main.async {
        onDidLaunch()
      }
    }
  }

  private var launchOptions: WorkspaceAgentLaunchOptions? {
    if allowsCustomCommand && useCustom {
      let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
      let displayName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else { return nil }
      return WorkspaceAgentLaunchOptions(
        source: .custom(
          displayName: displayName.isEmpty ? defaultDisplayName(for: command) : displayName,
          command: command,
          icon: "terminal"
        ),
        sandboxEnabled: sandboxEnabled
      )
    }

    guard let selectedSavedAgent else { return nil }
    return WorkspaceAgentLaunchOptions(
      source: .savedProfile(selectedSavedAgent, yoloMode: yoloMode),
      sandboxEnabled: sandboxEnabled
    )
  }

  private func syncSelectedAgent() {
    guard !useCustom else { return }
    if let selectedAgentId,
      let selected = savedAgents.profiles.first(where: { $0.id == selectedAgentId }),
      agentAvailability.status(for: selected) != .unavailable
    {
      return
    }
    selectedAgentId =
      savedAgents.profiles.first(where: {
        agentAvailability.status(for: $0) == .available
      })?.id ?? savedAgents.profiles.first?.id
  }

  private func presentSandboxHelp() {
    showSandboxHelp = true
    guard !sandboxHelpLoading else { return }
    let repoRoot = workspaceState.target.repoRoot
    if sandboxHelp?.repoRoot == repoRoot, sandboxHelpError == nil {
      return
    }

    sandboxHelpLoading = true
    sandboxHelpError = nil

    Task {
      let result = await Task.detached(priority: .userInitiated) {
        Result {
          let defaults = try ArgonCLI.sandboxDefaults(repoRoot: repoRoot)
          let paths = try ArgonCLI.sandboxConfigPaths(repoRoot: repoRoot)
          return SandboxHelpData(repoRoot: repoRoot, defaults: defaults, paths: paths)
        }
      }.value

      sandboxHelpLoading = false
      switch result {
      case .success(let help):
        sandboxHelp = help
        sandboxHelpError = nil
      case .failure(let error):
        sandboxHelp = nil
        sandboxHelpError = error.localizedDescription
      }
    }
  }

  @ViewBuilder
  private func savedAgentCard(for profile: SavedAgentProfile) -> some View {
    let status = agentAvailability.status(for: profile)
    AgentPickerCard(
      profile: profile,
      status: status,
      isSelected: !useCustom && selectedAgentId == profile.id
    ) {
      selectedAgentId = profile.id
      useCustom = false
      if profile.yoloFlag.isEmpty {
        yoloMode = false
      }
    }
  }

  private func defaultDisplayName(for command: String) -> String {
    let base = command.split(separator: " ").first.map(String.init) ?? "Agent"
    return base.isEmpty ? "Agent" : base.capitalized
  }

  private func yoloSubtitle(for flag: String) -> String {
    sandboxEnabled ? "Appends \(flag)." : "Dangerous without sandbox enabled."
  }

  private var yoloSubtitleColor: Color {
    sandboxEnabled ? .secondary : .red
  }
}

private struct WorkspaceNewWorktreeSheet: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @Binding var isPresented: Bool

  @State private var branchName = ""
  @State private var path = ""
  @State private var startPoint = ""
  @State private var lastSuggestedPath = ""
  @State private var hasCustomizedPath = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "square.stack.badge.plus")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("New Worktree")
            .font(.title2.weight(.semibold))
          Text("Create a branch-backed worktree and focus it in this workspace.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Branch name")
            .font(.callout.weight(.medium))
          TextField("feature/refocus-workspace", text: $branchName)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Path")
            .font(.callout.weight(.medium))
          TextField("/path/to/worktree", text: $path)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

          Text("Suggested under the configured worktree root, but fully editable.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Start from")
            .font(.callout.weight(.medium))
          TextField("HEAD", text: $startPoint)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

          Text("Defaults to the inferred base branch for the repository.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack {
        Spacer()

        Button("Cancel") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)

        Button {
          createWorktree()
        } label: {
          if workspaceState.isCreatingWorktree {
            ProgressView()
              .frame(width: 90)
          } else {
            Text("Create Worktree")
              .frame(width: 90)
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canCreate)
      }
    }
    .padding(24)
    .frame(width: 520)
    .onAppear {
      let suggestedPath = workspaceState.suggestedWorktreePath(branchName: branchName)
      path = suggestedPath
      lastSuggestedPath = suggestedPath
      startPoint = workspaceState.defaultNewWorktreeStartPoint()
    }
    .onChange(of: branchName) { previousValue, newValue in
      let suggestion = workspaceState.suggestedWorktreePath(branchName: newValue)
      if !hasCustomizedPath || path == lastSuggestedPath || previousValue.isEmpty {
        path = suggestion
      }
      lastSuggestedPath = suggestion
      hasCustomizedPath = path != suggestion
    }
    .onChange(of: path) { _, newValue in
      hasCustomizedPath = newValue != lastSuggestedPath
    }
  }

  private var canCreate: Bool {
    !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !workspaceState.isCreatingWorktree
  }

  private func createWorktree() {
    Task {
      do {
        try await workspaceState.createWorktree(
          branchName: branchName,
          path: path,
          startPoint: startPoint
        )
        isPresented = false
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }
}

private struct WorkspaceInspectorPane: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @Environment(ReviewWindowRegistry.self) private var reviewWindowRegistry
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    @Bindable var workspaceState = workspaceState

    GeometryReader { proxy in
      Group {
        if let worktree = workspaceState.selectedWorktree {
          VStack(alignment: .leading, spacing: 14) {
            WorkspaceSurface {
              VStack(alignment: .leading, spacing: 12) {
                WorkspaceCompactDiffSummary(summary: workspaceState.selectedSummary)

                if workspaceState.hasConflicts(for: worktree.path) {
                  WorkspaceStatusPill(label: "conflicts", tint: .orange)
                }

                Divider()
                  .padding(.vertical, 2)

                WorkspacePrimaryActionButton(
                  title: "Review",
                  systemImage: "arrow.trianglehead.branch",
                  showsProgress: isPreparingReview(for: worktree.path),
                  isDisabled: workspaceState.isPresentingReviewAgentPicker
                ) {
                  handleReviewButton(for: worktree.path)
                }

                HStack(spacing: 8) {
                  WorkspaceEditorLauncher(worktreePath: worktree.path)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                  if let pullRequestURL = workspaceState.selectedPullRequestURL {
                    Button {
                      openPullRequest(urlString: pullRequestURL)
                    } label: {
                      Label("PR", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                  }
                }

                WorkspaceFinderLauncher(worktreePath: worktree.path)
                  .frame(maxWidth: .infinity)
              }
            }
            .fixedSize(horizontal: false, vertical: true)

            WorkspaceChangedFilesPane()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .padding(16)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          ContentUnavailableView(
            "No Selection",
            systemImage: "sidebar.right",
            description: Text("Select a worktree to view details and launch review.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(width: 0.5)
    }
    .sheet(
      isPresented: $workspaceState.isPresentingReviewAgentPicker,
      onDismiss: {
        workspaceState.dismissReviewAgentPicker()
      }
    ) {
      WorkspaceReviewAgentPickerSheet(
        candidates: workspaceState.reviewAgentCandidates,
        onSelect: { tabID in
          workspaceState.chooseReviewAgentTab(tabID)
        },
        onCancel: {
          workspaceState.dismissReviewAgentPicker()
        }
      )
    }
    .onChange(of: workspaceState.pendingReviewAgentTabID) { _, tabID in
      guard let tabID else { return }
      workspaceState.pendingReviewAgentTabID = nil
      launchReview(using: tabID)
    }
  }

  private func launchReview(using agentTabID: UUID) {
    Task {
      do {
        let target: ReviewTarget
        if let preparedTarget = workspaceState.consumePreparedReviewTarget(for: agentTabID) {
          target = preparedTarget
        } else {
          target = try await workspaceState.createReviewTarget(launchContext: .coderHandoff)
          do {
            let prompt = try await Task.detached {
              try ArgonCLI.agentPrompt(sessionId: target.sessionId, repoRoot: target.repoRoot)
            }.value
            let injected = await GhosttyTerminalView.injectPrompt(prompt, into: agentTabID)
            if !injected {
              workspaceState.errorMessage =
                "Opened the review, but Argon could not hand off the session prompt to the selected agent tab."
            }
          } catch {
            workspaceState.errorMessage =
              "Opened the review, but Argon could not build the agent handoff prompt: \(error.localizedDescription)"
          }
        }
        reviewWindowRegistry.open(target: target) { target in
          openWindow(value: target)
        }
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  private func handleReviewButton(for worktreePath: String) {
    if reviewWindowRegistry.bringToFront(repoRoot: worktreePath) {
      return
    }

    guard reviewWindowRegistry.state(for: worktreePath) != .opening else { return }
    workspaceState.beginReviewLaunchFlow()
  }

  private func isPreparingReview(for worktreePath: String) -> Bool {
    if workspaceState.isLaunchingReview {
      return true
    }

    return reviewWindowRegistry.state(for: worktreePath) == .opening
  }

  private func openPullRequest(urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct WorkspaceReviewAgentPickerSheet: View {
  let candidates: [WorkspaceTerminalTab]
  let onSelect: (UUID) -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 10) {
        Image(systemName: "person.crop.circle.badge.questionmark")
          .font(.title2)
          .foregroundStyle(.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("Choose Agent")
            .font(.title2.weight(.semibold))
          Text("Select the live agent tab that should receive the review handoff.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        ForEach(candidates) { tab in
          Button {
            onSelect(tab.id)
          } label: {
            HStack(spacing: 12) {
              AgentIconView(icon: tab.kind.iconName, size: 18)
                .frame(width: 22, height: 22)
              VStack(alignment: .leading, spacing: 3) {
                Text(tab.title)
                  .font(.headline)
                Text(tab.commandDescription)
                  .font(.callout.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
          }
          .buttonStyle(.plain)
        }
      }

      HStack {
        Spacer()

        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

private struct WorkspacePrimaryActionButton: View {
  let title: String
  let systemImage: String
  let showsProgress: Bool
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Label(title, systemImage: systemImage)
          .font(.headline.weight(.semibold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)

        HStack {
          Spacer()

          Group {
            if showsProgress {
              ProgressView()
                .controlSize(.small)
                .tint(.white)
            } else {
              Color.clear
            }
          }
          .frame(width: 14, height: 14)
        }
      }
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity)
      .frame(height: 36)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.accentColor.opacity(isDisabled ? 0.82 : 1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.accentColor.opacity(0.14), lineWidth: isDisabled ? 1 : 0)
      )
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .allowsHitTesting(!isDisabled)
    .accessibilityLabel(title)
    .accessibilityHint(
      isDisabled
        ? "Close the review window to enable review for this worktree again."
        : "Open a review window for the selected worktree."
    )
  }
}

private struct WorkspaceSurface<Content: View>: View {
  let fillColor: Color
  @ViewBuilder let content: Content

  init(
    fillColor: Color = Color(nsColor: .controlBackgroundColor).opacity(0.88),
    @ViewBuilder content: () -> Content
  ) {
    self.fillColor = fillColor
    self.content = content()
  }

  var body: some View {
    content
      .padding(18)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(fillColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(Color.primary.opacity(0.06), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.03), radius: 14, y: 4)
  }
}

private struct WorkspaceBackground: View {
  var body: some View {
    LinearGradient(
      colors: [
        Color(nsColor: .windowBackgroundColor),
        Color(nsColor: .controlBackgroundColor).opacity(0.94),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .overlay(alignment: .topLeading) {
      Circle()
        .fill(Color.accentColor.opacity(0.14))
        .frame(width: 320, height: 320)
        .blur(radius: 100)
        .offset(x: -80, y: -140)
    }
    .overlay(alignment: .bottomTrailing) {
      Circle()
        .fill(Color.orange.opacity(0.07))
        .frame(width: 300, height: 300)
        .blur(radius: 100)
        .offset(x: 80, y: 120)
    }
    .overlay(alignment: .trailing) {
      Circle()
        .fill(Color.blue.opacity(0.05))
        .frame(width: 220, height: 220)
        .blur(radius: 90)
        .offset(x: 100, y: -30)
    }
  }
}

private struct WorkspaceBanner: View {
  let message: String
  let symbolName: String
  let tint: Color
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
      Text(message)
        .lineLimit(2)
      Spacer()
      Button(action: onDismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .foregroundStyle(tint.opacity(0.85))
    }
    .font(.caption)
    .foregroundStyle(tint)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(tint.opacity(0.08))
  }
}

private struct WorkspaceBadge: View {
  let label: String
  let tint: Color

  var body: some View {
    Text(label)
      .font(.system(size: 10, weight: .semibold, design: .monospaced))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(tint.opacity(0.12), in: Capsule())
      .foregroundStyle(tint)
  }
}

private struct WorkspaceCompactDiffSummary: View {
  let summary: WorktreeDiffSummary

  var body: some View {
    Group {
      if summary.hasChanges {
        HStack(spacing: 4) {
          Text(fileCountLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)

          Text("+\(formatted(summary.addedLineCount))")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(Color(nsColor: .systemGreen))

          Text("-\(formatted(summary.removedLineCount))")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(Color(nsColor: .systemRed))

          DiffStatBar(added: summary.addedLineCount, removed: summary.removedLineCount)
        }
      } else {
        Text("no changes")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .fixedSize()
  }

  private var fileCountLabel: String {
    let count = summary.fileCount
    return count == 1 ? "1 file" : "\(formatted(count)) files"
  }

  private func formatted(_ value: Int) -> String {
    WorkspaceCompactDiffSummary.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }

  private static let numberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter
  }()
}

private struct WorkspaceEditorLauncher: View {
  @Environment(WorkspaceState.self) private var workspaceState
  let worktreePath: String
  @State private var editors: [DetectedEditorApp] = []
  @State private var preferredBundleIdentifier: String?
  @State private var openingBundleIdentifier: String?

  var body: some View {
    Group {
      if let preferredEditor {
        HStack(spacing: 0) {
          Button {
            openEditor(preferredEditor)
          } label: {
            HStack(spacing: 8) {
              Image(nsImage: EditorLocator.icon(for: preferredEditor, size: 16))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)

              if openingBundleIdentifier == preferredEditor.bundleIdentifier {
                ProgressView()
                  .controlSize(.small)
              } else {
                Text("Open in \(preferredEditor.displayName)")
                  .lineLimit(1)
              }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
          }
          .buttonStyle(.plain)
          .disabled(openingBundleIdentifier != nil)

          if !alternativeEditors.isEmpty {
            Rectangle()
              .fill(Color.primary.opacity(0.08))
              .frame(width: 1)
              .padding(.vertical, 6)

            Menu {
              ForEach(alternativeEditors) { editor in
                Button {
                  openEditor(editor)
                } label: {
                  HStack(spacing: 8) {
                    Image(nsImage: EditorLocator.icon(for: editor, size: 16))
                      .resizable()
                      .aspectRatio(contentMode: .fit)
                      .frame(width: 16, height: 16)
                    Text(editor.displayName)
                  }
                }
              }
            } label: {
              Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 30, height: 30)
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .disabled(openingBundleIdentifier != nil)
            .help("Choose another editor")
          }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 32, maxHeight: 32)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
      } else {
        Button {
          loadEditors()
        } label: {
          Label("No Editor Found", systemImage: "questionmark.app.dashed")
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.bordered)
      }
    }
    .task(id: worktreePath) {
      loadEditors()
    }
  }

  private var preferredEditor: DetectedEditorApp? {
    if let preferredBundleIdentifier,
      let preferredEditor = editors.first(where: {
        $0.bundleIdentifier == preferredBundleIdentifier
      })
    {
      return preferredEditor
    }

    return EditorPreferenceStore.preferredEditor(for: worktreePath, among: editors)
  }

  private var alternativeEditors: [DetectedEditorApp] {
    EditorPreferenceStore.alternativeEditors(for: worktreePath, among: editors)
  }

  private func loadEditors() {
    editors = EditorLocator.discoverInstalledEditors()
    preferredBundleIdentifier = EditorPreferenceStore.preferredBundleIdentifier(for: worktreePath)
  }

  private func chooseEditor(_ editor: DetectedEditorApp) {
    preferredBundleIdentifier = editor.bundleIdentifier
    EditorPreferenceStore.setPreferredBundleIdentifier(
      editor.bundleIdentifier,
      for: worktreePath
    )
  }

  private func openEditor(_ editor: DetectedEditorApp) {
    chooseEditor(editor)
    openingBundleIdentifier = editor.bundleIdentifier

    Task {
      do {
        try await EditorLocator.open(editor, worktreePath: worktreePath)
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
      openingBundleIdentifier = nil
    }
  }
}

private struct WorkspaceFinderLauncher: View {
  let worktreePath: String
  private let bundleIdentifier = "com.apple.finder"

  var body: some View {
    Button {
      NSWorkspace.shared.open(URL(fileURLWithPath: worktreePath))
    } label: {
      HStack(spacing: 8) {
        Image(nsImage: finderIcon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 16, height: 16)
        Text("Open in Finder")
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
    .frame(minHeight: 32, maxHeight: 32)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }

  private var finderIcon: NSImage {
    if let applicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: bundleIdentifier)
    {
      return EditorLocator.icon(
        for: DetectedEditorApp(
          bundleIdentifier: bundleIdentifier,
          displayName: "Finder",
          applicationURL: applicationURL
        ),
        size: 16
      )
    }

    return NSWorkspace.shared.icon(for: .folder)
  }
}
