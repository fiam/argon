import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func workspaceSidebarAccessibilityIdentifier(for path: String) -> String {
  let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
    (partial ^ UInt64(byte)) &* 1_099_511_628_211
  }
  let lastComponent = URL(fileURLWithPath: path).lastPathComponent
  return "workspace-sidebar-row-\(lastComponent)-\(String(hash, radix: 16))"
}

struct WorkspaceWindowView: View {
  @Environment(CommandContext.self) private var commandContext
  @Environment(WorkspaceWindowRegistry.self) private var workspaceWindowRegistry
  let target: WorkspaceTarget
  let workspaceState: WorkspaceState

  init(target: WorkspaceTarget, workspaceState: WorkspaceState) {
    self.target = target
    self.workspaceState = workspaceState
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
      .navigationTitle(workspaceState.windowTitle)
      .onAppear {
        if workspaceState.worktrees.isEmpty && !workspaceState.isLoading {
          workspaceState.load()
        }
      }
  }
}

private struct WorkspaceContentView: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @Environment(ReviewWindowRegistry.self) private var reviewWindowRegistry
  @Environment(\.openWindow) private var openWindow
  @State private var showInspector = true

  var body: some View {
    @Bindable var workspaceState = workspaceState

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
      }
    }
    .overlay(alignment: .top) {
      VStack(spacing: 8) {
        if let launchWarningMessage = workspaceState.launchWarningMessage {
          WorkspaceToast(
            message: launchWarningMessage,
            symbolName: "arrow.turn.up.left.circle.fill",
            tint: .orange,
            accessibilityIdentifier: "workspace-launch-warning-toast"
          ) {
            withAnimation(.easeInOut(duration: 0.2)) {
              workspaceState.launchWarningMessage = nil
            }
          }
        }
        if let restoreFailureMessage = workspaceState.restoreFailureMessage {
          WorkspaceToast(
            message: restoreFailureMessage,
            symbolName: "terminal.fill",
            tint: .orange,
            accessibilityIdentifier: "workspace-restore-failure-toast"
          ) {
            withAnimation(.easeInOut(duration: 0.2)) {
              workspaceState.restoreFailureMessage = nil
            }
          }
        }
      }
      .padding(.top, 10)
      .transition(.move(edge: .top).combined(with: .opacity))
    }
    .task(id: workspaceState.launchWarningMessage) {
      guard let launchWarningMessage = workspaceState.launchWarningMessage else { return }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      if workspaceState.launchWarningMessage == launchWarningMessage {
        withAnimation(.easeInOut(duration: 0.2)) {
          workspaceState.launchWarningMessage = nil
        }
      }
    }
    .task(id: workspaceState.restoreFailureMessage) {
      guard let restoreFailureMessage = workspaceState.restoreFailureMessage else { return }
      UITestAutomationSignal.write(
        "workspace-restore-failure-toast-shown",
        to: UITestAutomationConfig.current().signalFilePath
      )
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      if workspaceState.restoreFailureMessage == restoreFailureMessage {
        withAnimation(.easeInOut(duration: 0.2)) {
          workspaceState.restoreFailureMessage = nil
        }
      }
    }
    .animation(
      .easeInOut(duration: 0.2),
      value: workspaceState.launchWarningMessage != nil
        || workspaceState.restoreFailureMessage != nil
    )
    .toolbar {
      if workspaceState.selectedWorktree != nil {
        WorkspaceToolbarItems(
          showsFinalizeControls: workspaceState.canFinalizeSelectedWorktree,
          showsReviewProgress: isPreparingSelectedWorktreeReview,
          isReviewDisabled: workspaceState.isPresentingReviewAgentPicker,
          canRebase: workspaceState.canRebaseSelectedWorktree,
          canMergeBack: workspaceState.canMergeBackSelectedWorktree,
          canOpenPR: workspaceState.canOpenPullRequestForSelectedWorktree,
          onPresentTabCreator: { workspaceState.presentTabCreationSheet() },
          onReview: handleSelectedWorktreeReviewButton,
          onRebase: { workspaceState.beginRebaseFlow() },
          onMergeBack: { workspaceState.beginMergeBackFlow() },
          onOpenPR: { workspaceState.beginOpenPullRequestFlow() }
        )
      }
    }
    .sheet(
      isPresented: $workspaceState.isPresentingReviewAgentPicker,
      onDismiss: {
        workspaceState.dismissReviewAgentPicker()
      }
    ) {
      WorkspaceAgentPickerSheet(
        title: "Choose Agent",
        subtitle: "Select the live agent tab that should receive the review handoff.",
        candidates: workspaceState.reviewAgentCandidates,
        onSelect: { tabID in
          workspaceState.chooseReviewAgentTab(tabID)
        },
        onCancel: {
          workspaceState.dismissReviewAgentPicker()
        }
      )
    }
    .sheet(
      isPresented: $workspaceState.isPresentingFinalizeAgentPicker,
      onDismiss: {
        workspaceState.dismissFinalizeAgentPicker(
          resetAction: workspaceState.pendingFinalizeAgentTabID == nil
        )
      }
    ) {
      WorkspaceAgentPickerSheet(
        title: "Choose Agent",
        subtitle: workspaceState.activeFinalizeAction?.pickerSubtitle
          ?? "Select the live agent tab that should receive the finalize task.",
        candidates: workspaceState.finalizeAgentCandidates,
        onSelect: { tabID in
          workspaceState.chooseFinalizeAgentTab(tabID)
        },
        onCancel: {
          workspaceState.dismissFinalizeAgentPicker()
        }
      )
    }
    .confirmationDialog(
      "Merge Back",
      isPresented: $workspaceState.isPresentingMergeBackOptions,
      titleVisibility: .visible
    ) {
      ForEach(workspaceState.mergeBackOptions) { action in
        Button(action.optionTitle) {
          workspaceState.chooseMergeBackAction(action)
        }
      }
      Button("Cancel", role: .cancel) {
        workspaceState.dismissMergeBackOptions()
      }
    } message: {
      Text(mergeBackDialogMessage)
    }
    .alert(
      workspaceState.pendingShellSandboxfilePrompt?.title ?? "Create Sandboxfile?",
      isPresented: pendingShellSandboxfileAlertIsPresented
    ) {
      Button(workspaceState.pendingShellSandboxfilePrompt?.confirmTitle ?? "Create and Launch") {
        workspaceState.confirmSandboxedShellLaunch()
      }
      Button("Cancel", role: .cancel) {
        workspaceState.dismissShellSandboxfilePrompt()
      }
    } message: {
      if let prompt = workspaceState.pendingShellSandboxfilePrompt {
        Text(prompt.message)
      }
    }
    .onChange(of: workspaceState.pendingReviewAgentTabID) { _, tabID in
      guard let tabID else { return }
      workspaceState.pendingReviewAgentTabID = nil
      launchReview(using: tabID)
    }
    .onChange(of: workspaceState.pendingFinalizeAgentTabID) { _, tabID in
      guard let tabID else { return }
      launchFinalize(using: tabID)
    }
  }

  private var isPreparingSelectedWorktreeReview: Bool {
    guard let worktreePath = workspaceState.selectedWorktree?.path else { return false }
    if workspaceState.isLaunchingReview {
      return true
    }
    return reviewWindowRegistry.state(for: worktreePath) == .opening
  }

  private var pendingShellSandboxfileAlertIsPresented: Binding<Bool> {
    Binding(
      get: { workspaceState.pendingShellSandboxfilePrompt != nil },
      set: { isPresented in
        if !isPresented {
          workspaceState.dismissShellSandboxfilePrompt()
        }
      }
    )
  }

  private func handleSelectedWorktreeReviewButton() {
    guard let worktreePath = workspaceState.selectedWorktree?.path else { return }

    if reviewWindowRegistry.bringToFront(repoRoot: worktreePath) {
      return
    }

    guard reviewWindowRegistry.state(for: worktreePath) != .opening else { return }
    workspaceState.beginReviewLaunchFlow()
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

  private func launchFinalize(using agentTabID: UUID) {
    Task {
      defer {
        workspaceState.finishFinalizeFlow()
      }

      guard let action = workspaceState.activeFinalizeAction else { return }

      do {
        let prompt = try workspaceState.finalizePrompt(for: action)
        let injected = await GhosttyTerminalView.injectPrompt(prompt, into: agentTabID)
        if !injected {
          workspaceState.errorMessage =
            "Argon could not hand off the \(action.title.lowercased()) prompt to the selected agent tab."
        }
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  private var mergeBackDialogMessage: String {
    guard let topology = workspaceState.selectedBranchTopology else {
      return "Choose how to land this worktree on the base branch."
    }

    if topology.needsRebase {
      return
        "The base branch has moved ahead. Choose how to land this worktree back onto the updated base branch."
    }

    return "Choose how to land this worktree back onto the base branch."
  }
}

private struct WorkspaceSidebar: View {
  @Environment(WorkspaceState.self) private var workspaceState
  @State private var showNewWorktreeSheet = false

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        if workspaceState.worktrees.isEmpty && workspaceState.isLoading {
          Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspaceState.worktrees.isEmpty {
          ContentUnavailableView(
            "No Worktrees",
            systemImage: "square.stack.3d.up.slash",
            description: Text("Open a Git repository to populate the workspace.")
          )
        } else {
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(workspaceState.worktrees) { worktree in
                WorkspaceSidebarRow(
                  worktree: worktree,
                  isSelected: workspaceState.selectedWorktree?.path == worktree.path
                ) {
                  workspaceState.selectWorktree(path: worktree.path)
                }
              }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 10)
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
    .background(Color(nsColor: .controlBackgroundColor))
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
  let isSelected: Bool
  let onSelect: () -> Void
  @State private var isHovering = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: onSelect) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(worktree.branchName ?? "Detached HEAD")
              .font(.body.weight(.semibold))
              .lineLimit(1)

            if worktree.isBaseWorktree {
              WorkspaceBadge(label: "Base", tint: Color(nsColor: .controlAccentColor))
            } else if worktree.isDetached {
              WorkspaceBadge(label: "Detached", tint: .orange)
            }

            Spacer(minLength: 0)
          }
          .padding(.trailing, hoverActionsInset)

          HStack(spacing: 10) {
            WorkspaceCompactDiffSummary(summary: summary)

            if needsAttention {
              WorkspaceSidebarMetadataItem(
                label: "Needs attention",
                symbolTint: .orange,
                accessibilityIdentifier: "workspace-sidebar-needs-attention"
              )
            }

            if hasConflicts {
              WorkspaceSidebarMetadataItem(
                label: "Conflicts",
                symbolTint: .orange,
                accessibilityIdentifier: "workspace-sidebar-conflicts"
              )
            }

            if activeAgentCount > 0 {
              WorkspaceSidebarMetadataItem(
                label: activeAgentCount == 1 ? "1 agent" : "\(activeAgentCount) agents"
              )
            }

            Spacer(minLength: 0)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(rowBackground)
        )
        .overlay {
          if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(workspaceSidebarAccessibilityIdentifier(for: worktree.path))

      WorkspaceSidebarHoverActions(
        worktree: worktree,
        isVisible: isHovering
      )
      .padding(8)
    }
    .onHover { hovering in
      isHovering = hovering
    }
  }

  private var hoverActionsInset: CGFloat {
    worktree.isBaseWorktree ? 28 : 56
  }

  private var rowBackground: Color {
    if isSelected {
      return Color.accentColor.opacity(0.14)
    }

    return isHovering ? Color.primary.opacity(0.05) : .clear
  }

  private var summary: WorktreeDiffSummary {
    workspaceState.summary(for: worktree.path)
  }

  private var hasConflicts: Bool {
    workspaceState.hasConflicts(for: worktree.path)
  }

  private var needsAttention: Bool {
    workspaceState.worktreeNeedsAttention(for: worktree.path)
  }

  private var activeAgentCount: Int {
    workspaceState.activeAgentCount(for: worktree.path)
  }
}

private struct WorkspaceSidebarMetadataItem: View {
  let label: String
  var symbolTint: Color? = nil
  var accessibilityIdentifier: String? = nil

  var body: some View {
    HStack(spacing: 4) {
      if let symbolTint {
        Circle()
          .fill(symbolTint)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
      }

      Text(label)
        .lineLimit(1)
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(label))
    .accessibilityIdentifier(accessibilityIdentifier ?? "")
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

private struct WorkspaceToolbarItems: ToolbarContent {
  let showsFinalizeControls: Bool
  let showsReviewProgress: Bool
  let isReviewDisabled: Bool
  let canRebase: Bool
  let canMergeBack: Bool
  let canOpenPR: Bool
  let onPresentTabCreator: () -> Void
  let onReview: () -> Void
  let onRebase: () -> Void
  let onMergeBack: () -> Void
  let onOpenPR: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button(action: onPresentTabCreator) {
        Image(systemName: "plus")
      }
      .help("New tab")
      .accessibilityLabel("New Tab")
    }

    if #available(macOS 26.0, *) {
      ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    ToolbarItem(placement: .primaryAction) {
      Button(action: onReview) {
        Image(systemName: showsReviewProgress ? "ellipsis" : "text.magnifyingglass")
      }
      .help(
        isReviewDisabled
          ? "Close the review window to enable review for this worktree again."
          : "Start review"
      )
      .accessibilityLabel("Start Review")
      .disabled(isReviewDisabled)
    }

    ToolbarItem(placement: .primaryAction) {
      Button(action: onRebase) {
        Image(systemName: "arrow.clockwise")
      }
      .help(rebaseHelpText)
      .accessibilityLabel("Rebase onto Base")
      .disabled(!showsFinalizeControls || !canRebase)
    }

    ToolbarItem(placement: .primaryAction) {
      Button(action: onMergeBack) {
        Image(systemName: "arrow.triangle.branch")
      }
      .help(mergeBackHelpText)
      .accessibilityLabel("Merge Back")
      .disabled(!showsFinalizeControls || !canMergeBack)
    }

    ToolbarItem(placement: .primaryAction) {
      Button(action: onOpenPR) {
        Image(systemName: "arrow.up.forward.app")
      }
      .help(openPRHelpText)
      .accessibilityLabel("Open Pull Request")
      .disabled(!showsFinalizeControls || !canOpenPR)
    }
  }

  private var rebaseHelpText: String {
    if !showsFinalizeControls {
      return "The base worktree cannot be rebased onto itself."
    }
    if !canRebase {
      return "Rebase is only available when this worktree is behind the base branch."
    }
    return "Rebase onto base branch"
  }

  private var mergeBackHelpText: String {
    if !showsFinalizeControls {
      return "The base worktree is already the landing branch."
    }
    if !canMergeBack {
      return "Merge Back is only available when this worktree has commits to land."
    }
    return "Merge back to base branch"
  }

  private var openPRHelpText: String {
    if !showsFinalizeControls {
      return "The base worktree does not open pull requests against itself."
    }
    if !canOpenPR {
      return "Open Pull Request is only available when this worktree has commits to propose."
    }
    return "Open pull request"
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
  @Environment(ReviewWindowRegistry.self) private var reviewWindowRegistry
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    @Bindable var workspaceState = workspaceState

    VStack(spacing: 0) {
      if !workspaceState.selectedTerminalTabs.isEmpty {
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

  private func launchWorkspaceAgent(_ options: WorkspaceAgentLaunchOptions) async -> Bool {
    do {
      try await workspaceState.launchAgent(using: options)
      return true
    } catch {
      workspaceState.errorMessage = error.localizedDescription
      return false
    }
  }

  private func launchExternalReview() async -> Bool {
    do {
      let target = try await workspaceState.createReviewTarget(launchContext: .externalHandoff)
      do {
        let prompt = try await Task.detached {
          try ArgonCLI.agentPrompt(sessionId: target.sessionId, repoRoot: target.repoRoot)
        }.value
        copyToPasteboard(prompt)
        reviewWindowRegistry.open(target: target) { target in
          openWindow(value: target)
        }
        return true
      } catch {
        try? await Task.detached {
          try ArgonCLI.closeSession(sessionId: target.sessionId, repoRoot: target.repoRoot)
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
          if case .agent = tab.kind {
            AgentIconView(icon: resolvedAgentTabIconName, size: 12)
              .foregroundStyle(.primary)
          } else {
            Image(systemName: tab.isSandboxed ? "terminal" : "lock.open")
              .font(.system(size: 11, weight: .medium))
          }

          Circle()
            .fill(attentionIndicatorColor)
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

  private var attentionIndicatorColor: Color {
    if tab.hasAttention {
      return .orange
    }
    return tab.isRunning ? Color(nsColor: .systemGreen) : .secondary
  }

  private var resolvedAgentTabIconName: String {
    guard case .agent(_, let icon) = tab.kind else { return "agent" }
    switch icon {
    case "claude", "codex", "gemini":
      return icon
    default:
      return "agent"
    }
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
          waitAfterCommand: waitAfterCommand(for: tab),
          onProcessExit: {
            workspaceState.handleTerminalExit(
              tab.id,
              exitBehavior: selectedFinishedTerminalBehavior
            )
          },
          onAttention: { event in
            workspaceState.markTerminalNeedsAttention(tab.id)
            terminalAttentionNotifier.postAttentionNotification(
              event: event,
              repoRoot: workspaceState.target.repoRoot,
              tab: tab
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
          onNewShell: { workspaceState.requestSandboxedShellLaunch() }
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

  private var effectiveTerminalFontSize: Double {
    GhosttyConfigurationSettings.fontSize(from: ghosttyConfigurationText)
      ?? terminalFontSizeFallback
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
  let taskContext: WorkspaceAgentTaskContext
  let onLaunch: @MainActor (WorkspaceAgentLaunchOptions) async -> Bool
  let onExternalLaunch: @MainActor () async -> Bool
  let onDidLaunch: @MainActor () -> Void

  @State private var selectedAgentId: String?
  @State private var yoloMode = true
  @State private var sandboxEnabled = true
  @State private var customCommand = ""
  @State private var useCustom = false
  @State private var isLaunching = false
  @State private var showSandboxHelp = false
  @State private var sandboxHelp: SandboxHelpData?
  @State private var sandboxHelpError: String?
  @State private var sandboxHelpLoading = false
  @State private var pendingSandboxfilePrompt: SandboxfilePromptRequest?
  @State private var pendingSandboxedLaunchOptions: WorkspaceAgentLaunchOptions?

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

          if taskContext.showsExternalOption {
            ExternalAgentPickerCard {
              launchExternal()
            }
            .disabled(isLaunching)
            .accessibilityIdentifier("workspace-review-external-button")
          }

          if taskContext.allowsCustomCommand {
            CustomAgentPickerCard(isSelected: useCustom, accentColor: .accentColor) {
              useCustom = true
              selectedAgentId = nil
              yoloMode = false
            }
          }
        }
      }

      if taskContext.allowsCustomCommand && useCustom {
        VStack(alignment: .leading, spacing: 8) {
          TextField("Command", text: $customCommand, prompt: Text("e.g. codex --yolo"))
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
    .onChange(of: taskContext.allowsCustomCommand) { _, allowsCustomCommand in
      if !allowsCustomCommand {
        useCustom = false
      }
    }
    .alert(
      pendingSandboxfilePrompt?.title ?? "Create Sandboxfile?",
      isPresented: pendingSandboxfileAlertIsPresented
    ) {
      Button(pendingSandboxfilePrompt?.confirmTitle ?? "Create and Launch") {
        confirmSandboxedLaunch()
      }
      Button("Cancel", role: .cancel) {
        pendingSandboxedLaunchOptions = nil
        pendingSandboxfilePrompt = nil
      }
    } message: {
      if let prompt = pendingSandboxfilePrompt {
        Text(prompt.message)
      }
    }
  }

  private var canLaunch: Bool {
    guard !isLaunching else { return false }
    if taskContext.allowsCustomCommand && useCustom {
      return !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let selectedSavedAgent else { return false }
    return agentAvailability.status(for: selectedSavedAgent) == .available
  }

  private var pendingSandboxfileAlertIsPresented: Binding<Bool> {
    Binding(
      get: { pendingSandboxfilePrompt != nil },
      set: { isPresented in
        if !isPresented {
          pendingSandboxedLaunchOptions = nil
          pendingSandboxfilePrompt = nil
        }
      }
    )
  }

  private var sheetTitle: String {
    taskContext.sheetTitle
  }

  private var sheetSubtitle: String {
    taskContext.sheetSubtitle
  }

  private func launch() {
    guard let launchOptions else { return }

    isLaunching = true
    Task { @MainActor in
      do {
        if launchOptions.sandboxEnabled,
          let prompt = try await loadSandboxfilePromptIfNeeded(
            repoRoot: workspaceState.target.repoRoot,
            launchKind: .agent
          )
        {
          pendingSandboxedLaunchOptions = launchOptions
          pendingSandboxfilePrompt = prompt
          isLaunching = false
          return
        }

        await performLaunch(launchOptions)
      } catch {
        isLaunching = false
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  private func confirmSandboxedLaunch() {
    guard let launchOptions = pendingSandboxedLaunchOptions,
      let prompt = pendingSandboxfilePrompt
    else { return }
    pendingSandboxedLaunchOptions = nil
    pendingSandboxfilePrompt = nil
    isLaunching = true

    Task { @MainActor in
      do {
        try await createRepoSandboxfile(request: prompt)
        await performLaunch(launchOptions)
      } catch {
        isLaunching = false
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  private func performLaunch(_ launchOptions: WorkspaceAgentLaunchOptions) async {
    let didLaunch = await onLaunch(launchOptions)
    isLaunching = false
    guard didLaunch else { return }
    isPresented = false
    DispatchQueue.main.async {
      onDidLaunch()
    }
  }

  private func launchExternal() {
    guard !isLaunching else { return }

    isLaunching = true
    Task { @MainActor in
      let didLaunch = await onExternalLaunch()
      isLaunching = false
      guard didLaunch else { return }
      isPresented = false
    }
  }

  private var launchOptions: WorkspaceAgentLaunchOptions? {
    if taskContext.allowsCustomCommand && useCustom {
      let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else { return nil }
      return WorkspaceAgentLaunchOptions(
        source: .custom(
          displayName: commandExecutableName(from: command),
          command: command,
          icon: "agent"
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
          let paths = try ArgonCLI.sandboxConfigPaths(repoRoot: repoRoot)
          return SandboxHelpData(repoRoot: repoRoot, paths: paths)
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

  private func yoloSubtitle(for flag: String) -> String {
    sandboxEnabled ? "Appends \(flag)." : "Dangerous without sandbox enabled."
  }

  private var yoloSubtitleColor: Color {
    sandboxEnabled ? .secondary : .red
  }
}

private enum WorkspaceAgentTaskContext {
  case general
  case reviewHandoff
  case finalize(WorktreeFinalizeAction)

  var allowsCustomCommand: Bool {
    switch self {
    case .general:
      false
    case .reviewHandoff, .finalize(_):
      true
    }
  }

  var showsExternalOption: Bool {
    if case .reviewHandoff = self {
      return true
    }
    return false
  }

  var sheetTitle: String {
    switch self {
    case .general:
      "New Agent Tab"
    case .reviewHandoff:
      "Launch Review Agent"
    case .finalize(let action):
      action.launchSheetTitle
    }
  }

  var sheetSubtitle: String {
    switch self {
    case .general:
      "Launch a saved agent in the selected worktree."
    case .reviewHandoff:
      "Launch a coder tab here, or copy the review prompt for your own external agent."
    case .finalize(let action):
      action.launchSheetSubtitle
    }
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

          DirectoryPathControl(path: path) {
            chooseWorktreeDirectory()
          }
          .frame(height: 22)
          .help(path)

          HStack(spacing: 8) {
            Button("Use Suggested") {
              path = lastSuggestedPath
              hasCustomizedPath = false
            }
            .controlSize(.small)
            .disabled(path == lastSuggestedPath)
          }
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
          ZStack {
            Text("Create Worktree")
              .frame(minWidth: 120)
              .opacity(workspaceState.isCreatingWorktree ? 0 : 1)

            if workspaceState.isCreatingWorktree {
              ProgressView()
                .controlSize(.small)
            }
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

  private func chooseWorktreeDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Choose Worktree Destination"
    panel.message = "Select or create the destination directory for the new worktree."
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()

    guard panel.runModal() == .OK, let url = panel.url else { return }
    path = url.standardizedFileURL.path
    hasCustomizedPath = path != lastSuggestedPath
  }
}

private struct WorkspaceInspectorPane: View {
  @Environment(WorkspaceState.self) private var workspaceState

  var body: some View {
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

                WorkspaceEditorLauncher(worktreePath: worktree.path)
                  .frame(maxWidth: .infinity)
                  .layoutPriority(1)
              }
            }
            .fixedSize(horizontal: false, vertical: true)

            if let selectedTerminalTab = workspaceState.selectedTerminalTab,
              selectedTerminalTab.isSandboxed
            {
              WorkspaceSandboxNetworkPane(tab: selectedTerminalTab)
                .frame(maxWidth: .infinity)
            }

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
  }
}

private struct WorkspaceSandboxNetworkPane: View {
  let tab: WorkspaceTerminalTab

  @State private var events: [SandboxNetworkActivityEvent] = []
  @State private var lastVisibleEventID: String?

  var body: some View {
    WorkspaceSurface {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Label("Network", systemImage: "network")
            .font(.headline)
          Spacer()
          Text(tab.title)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if events.isEmpty {
          Text("No proxied network activity yet.")
            .font(.subheadline.weight(.medium))
        } else {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                  WorkspaceSandboxNetworkRow(event: event)
                    .id(event.id)
                  if index < events.count - 1 {
                    Divider()
                      .padding(.vertical, 10)
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
              scrollToNewestEvent(with: proxy, animated: false)
            }
            .onChange(of: events.map(\.id)) { _, _ in
              scrollToNewestEvent(with: proxy, animated: true)
            }
          }
          .frame(minHeight: 96, maxHeight: 220)
        }
      }
    }
    .task(id: tab.id) {
      await refreshLoop(for: tab.id)
    }
  }

  private func refreshLoop(for tabID: UUID) async {
    while !Task.isCancelled {
      let updatedEvents = SandboxNetworkActivityLogStore.loadEvents(for: tabID)
      if updatedEvents != events {
        withAnimation(.easeInOut(duration: 0.2)) {
          events = updatedEvents
        }
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private func scrollToNewestEvent(
    with proxy: ScrollViewProxy,
    animated: Bool
  ) {
    guard let newestEventID = events.last?.id, newestEventID != lastVisibleEventID else { return }
    lastVisibleEventID = newestEventID
    let action = {
      proxy.scrollTo(newestEventID, anchor: .bottom)
    }
    if animated {
      withAnimation(.easeInOut(duration: 0.2), action)
    } else {
      action()
    }
  }
}

private struct WorkspaceSandboxNetworkRow: View {
  let event: SandboxNetworkActivityEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(event.title)
          .font(.subheadline.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        Text(event.occurredAt, style: .time)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if let path = event.path, !path.isEmpty {
        Text(path)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      } else if let detail = event.detail, !detail.isEmpty {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      HStack(spacing: 10) {
        Text(event.statusLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(event.outcome == "denied" ? .orange : .secondary)
        Text(event.transferLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct WorkspaceAgentPickerSheet: View {
  let title: String
  let subtitle: String
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
          Text(title)
            .font(.title2.weight(.semibold))
          Text(subtitle)
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

private struct WorkspaceToast: View {
  let message: String
  let symbolName: String
  let tint: Color
  let accessibilityIdentifier: String?
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
      Text(message)
        .lineLimit(2)
      Button(action: onDismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .foregroundStyle(tint.opacity(0.85))
    }
    .font(.caption)
    .foregroundStyle(tint)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(message)
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.regularMaterial, in: Capsule())
    .overlay(
      Capsule()
        .stroke(tint.opacity(0.18), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    .padding(.horizontal, 16)
    .accessibilityIdentifier(accessibilityIdentifier ?? "workspace-toast")
  }
}

private struct WorkspaceBadge: View {
  let label: String
  let tint: Color

  var body: some View {
    Text(label)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(tint.opacity(0.08), in: Capsule())
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

private struct WorkspaceSidebarHoverActions: View {
  let worktree: DiscoveredWorktree
  let isVisible: Bool

  var body: some View {
    HStack(spacing: 4) {
      WorkspaceRevealInFinderButton(
        worktreePath: worktree.path,
        isVisible: isVisible
      )

      if !worktree.isBaseWorktree {
        WorkspaceRemoveWorktreeButton(
          worktree: worktree,
          isVisible: isVisible
        )
      }
    }
  }
}

private struct WorkspaceRevealInFinderButton: View {
  let worktreePath: String
  let isVisible: Bool

  var body: some View {
    Button {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktreePath)])
    } label: {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 20, height: 20)
        .padding(4)
        .background(
          Circle()
            .fill(Color.primary.opacity(showButton ? 0.08 : 0))
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .opacity(showButton ? 1 : 0)
    .allowsHitTesting(showButton)
    .help("Reveal worktree in Finder")
    .accessibilityLabel("Reveal in Finder")
  }

  private var showButton: Bool {
    isVisible
  }
}

private struct WorkspaceRemoveWorktreeButton: View {
  @Environment(WorkspaceState.self) private var workspaceState
  let worktree: DiscoveredWorktree
  let isVisible: Bool
  @State private var pendingRemoval: WorktreeRemovalRequest?
  @State private var deleteBranchOnConfirm = false
  @State private var isPreparingRemoval = false
  @State private var isRemoving = false

  var body: some View {
    Button(role: .destructive) {
      prepareRemoval()
    } label: {
      ZStack {
        Image(systemName: "trash")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.red)
          .opacity(isShowingProgress ? 0 : 1)

        if isShowingProgress {
          ProgressView()
            .controlSize(.small)
        }
      }
      .frame(width: 20, height: 20)
      .padding(4)
      .background(
        Circle()
          .fill(Color.red.opacity(showButton ? 0.12 : 0))
      )
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(isShowingProgress)
    .opacity(showButton ? 1 : 0)
    .allowsHitTesting(showButton)
    .help("Delete worktree")
    .accessibilityLabel("Delete worktree")
    .sheet(isPresented: isPresentingRemovalSheet) {
      if let pendingRemoval {
        WorkspaceRemoveWorktreeConfirmationSheet(
          request: pendingRemoval,
          deleteBranch: $deleteBranchOnConfirm,
          onCancel: { self.pendingRemoval = nil },
          onConfirm: { confirmRemoval() }
        )
      }
    }
  }

  private var isShowingProgress: Bool {
    isPreparingRemoval || isRemoving
  }

  private var showButton: Bool {
    isVisible || isShowingProgress
  }

  private var isPresentingRemovalSheet: Binding<Bool> {
    Binding(
      get: { pendingRemoval != nil },
      set: { isPresented in
        if !isPresented {
          pendingRemoval = nil
        }
      }
    )
  }

  private func prepareRemoval() {
    guard !isShowingProgress else { return }
    isPreparingRemoval = true

    Task {
      defer { isPreparingRemoval = false }
      do {
        let removalRequest = try await workspaceState.prepareWorktreeRemoval(for: worktree)
        if removalRequest.shouldSkipConfirmation {
          executeRemoval(removalRequest, deleteBranch: removalRequest.defaultDeletesBranch)
        } else {
          deleteBranchOnConfirm = removalRequest.defaultDeletesBranch
          pendingRemoval = removalRequest
        }
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }

  private func confirmRemoval() {
    guard let pendingRemoval else { return }
    self.pendingRemoval = nil
    executeRemoval(pendingRemoval, deleteBranch: deleteBranchOnConfirm)
  }

  private func executeRemoval(_ pendingRemoval: WorktreeRemovalRequest, deleteBranch: Bool) {
    isRemoving = true

    Task {
      defer { isRemoving = false }
      do {
        try await workspaceState.removeWorktree(pendingRemoval, deleteBranch: deleteBranch)
      } catch {
        workspaceState.errorMessage = error.localizedDescription
      }
    }
  }
}

private struct WorkspaceRemoveWorktreeConfirmationSheet: View {
  let request: WorktreeRemovalRequest
  @Binding var deleteBranch: Bool
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Delete \(request.displayName)?")
        .font(.title3.weight(.semibold))

      Text(removalMessage)
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if request.canDeleteBranch, let branchName = request.branchName {
        Toggle(isOn: $deleteBranch) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Delete branch \(branchName)")
              .font(.body.weight(.medium))
            Text(branchSubtitle)
              .font(.caption)
              .foregroundStyle(branchSubtitleColor)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .toggleStyle(.checkbox)
      }

      HStack(spacing: 10) {
        Spacer()

        Button("Cancel", role: .cancel) {
          onCancel()
        }

        Button(deleteButtonTitle, role: .destructive) {
          onConfirm()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 430)
  }

  private var removalMessage: String {
    if request.hasUncommittedChanges {
      return
        "This worktree has uncommitted changes. Deleting it will remove the worktree directory and discard those changes."
    }

    return "This will remove the linked worktree directory from disk."
  }

  private var deleteButtonTitle: String {
    if request.canDeleteBranch && deleteBranch {
      return "Delete Worktree and Branch"
    }

    return "Delete Worktree"
  }

  private var branchSubtitle: String {
    if request.branchHasUniqueCommits {
      if let baseRef = request.branchComparisonBaseRef {
        return "Contains commits not merged into \(baseRef)."
      }
      return "Contains commits that are not confirmed as merged."
    }

    if let baseRef = request.branchComparisonBaseRef {
      return "Already merged into \(baseRef)."
    }
    return "No unmerged commits detected."
  }

  private var branchSubtitleColor: Color {
    if request.branchHasUniqueCommits && deleteBranch {
      return .red
    }
    return .secondary
  }
}
