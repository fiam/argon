import AppKit
import SwiftUI

struct WorkspaceWindowView: View {
  @Environment(CommandContext.self) private var commandContext
  @Environment(WorkspaceWindowRegistry.self) private var workspaceWindowRegistry
  @AppStorage(AgentSleepPreventionSettings.enabledStorageKey)
  private var preventSleepWhileAgentsRun = AgentSleepPreventionSettings.defaultEnabled
  @State private var sleepPreventer = AgentSleepPreventer()
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
      .onChange(of: shouldPreventSleepForRunningAgents, initial: true) { _, shouldPrevent in
        sleepPreventer.setActive(shouldPrevent)
      }
      .onDisappear {
        sleepPreventer.setActive(false)
      }
      .onAppear {
        if workspaceState.worktrees.isEmpty && !workspaceState.isLoading {
          workspaceState.load()
        }
      }
      .task(id: workspaceState.worktrees.count) {
        workspaceState.applyUITestWebsiteDemoIfNeeded()
      }
  }

  private var shouldPreventSleepForRunningAgents: Bool {
    preventSleepWhileAgentsRun && workspaceState.runningAgentCount > 0
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
    .alert(
      workspaceState.worktreeRemovalErrorDialog?.title ?? "Couldn't Remove Worktree",
      isPresented: worktreeRemovalErrorIsPresented
    ) {
      Button("Close", role: .cancel) {
        workspaceState.dismissWorktreeRemovalError()
      }
    } message: {
      Text(workspaceState.worktreeRemovalErrorDialog?.message ?? "")
    }
    .toolbar {
      if workspaceState.selectedWorktree != nil {
        WorkspaceToolbarItems(
          showsFinalizeControls: workspaceState.canFinalizeSelectedWorktree,
          showsReviewProgress: isPreparingSelectedWorktreeReview,
          showsRebaseProgress: workspaceState.isRebaseInProgressForSelectedWorktree,
          showsMergeBackProgress: workspaceState.isMergeBackInProgressForSelectedWorktree,
          isReviewDisabled: workspaceState.isPresentingReviewPreparationSheet,
          canRebase: workspaceState.canRebaseSelectedWorktree,
          canMergeBack: workspaceState.canMergeBackSelectedWorktree,
          canOpenPR: workspaceState.canOpenPullRequestForSelectedWorktree,
          branchTopologyLabel: workspaceState.selectedBranchTopology?.displayLabel,
          onPresentTabCreator: { workspaceState.presentTabCreationSheet() },
          onReview: handleSelectedWorktreeReviewButton,
          onRebase: { workspaceState.beginRebaseFlow() },
          onMergeBack: { workspaceState.beginMergeBackFlow() },
          onOpenPR: { workspaceState.beginOpenPullRequestFlow() }
        )
      }
    }
    .sheet(
      isPresented: $workspaceState.isPresentingReviewPreparationSheet,
      onDismiss: {
        workspaceState.dismissReviewPreparationSheet()
      }
    ) {
      if let preparation = workspaceState.pendingReviewPreparation {
        WorkspaceReviewPreparationSheet(
          preparation: preparation,
          candidates: workspaceState.reviewAgentCandidates,
          onChange: { workspaceState.updatePendingReviewPreparation($0) },
          onLaunchAgent: {
            workspaceState.launchAgentForPendingReviewPreparation()
          },
          onStartReview: { preparation in
            startReview(using: preparation)
          },
          onCancel: {
            workspaceState.dismissReviewPreparationSheet()
          }
        )
      } else {
        Color.clear
          .frame(width: 1, height: 1)
          .onAppear {
            workspaceState.dismissReviewPreparationSheet()
          }
      }
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
    .sheet(isPresented: pendingShellSandboxfileWizardIsPresented) {
      if let prompt = workspaceState.pendingShellSandboxfilePrompt {
        SandboxfileWizardSheet(
          request: prompt,
          onCancel: {
            workspaceState.dismissShellSandboxfilePrompt()
          },
          onCreate: { configuration in
            workspaceState.confirmSandboxedShellLaunch(configuration: configuration)
          }
        )
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
    guard workspaceState.selectedWorktree != nil else { return false }
    if workspaceState.isLaunchingReview {
      return true
    }
    guard let sessionID = workspaceState.selectedReviewSnapshot?.sessionId.uuidString else {
      return false
    }
    return reviewWindowRegistry.state(forSessionID: sessionID) == .opening
  }

  private var pendingShellSandboxfileWizardIsPresented: Binding<Bool> {
    Binding(
      get: { workspaceState.pendingShellSandboxfilePrompt != nil },
      set: { isPresented in
        if !isPresented {
          workspaceState.dismissShellSandboxfilePrompt()
        }
      }
    )
  }

  private var worktreeRemovalErrorIsPresented: Binding<Bool> {
    Binding(
      get: { workspaceState.worktreeRemovalErrorDialog != nil },
      set: { isPresented in
        if !isPresented {
          workspaceState.dismissWorktreeRemovalError()
        }
      }
    )
  }

  private func handleSelectedWorktreeReviewButton() {
    WorkspaceReviewLauncher.startReview(
      workspaceState: workspaceState,
      reviewWindowRegistry: reviewWindowRegistry,
      openWindow: { target in openWindow(value: target) }
    )
  }

  private func launchReview(using agentTabID: UUID) {
    launchReview(using: agentTabID, changeSummary: nil)
  }

  private func launchReview(using agentTabID: UUID, changeSummary: String?) {
    WorkspaceReviewLauncher.launchReview(
      workspaceState: workspaceState,
      reviewWindowRegistry: reviewWindowRegistry,
      openWindow: { target in openWindow(value: target) },
      agentTabID: agentTabID,
      changeSummary: changeSummary
    )
  }

  private func startReview(using preparation: WorkspaceReviewPreparation) {
    let normalizedPreparation = preparation.normalized()
    workspaceState.updatePendingReviewPreparation(normalizedPreparation)
    guard let agentTabID = normalizedPreparation.selectedAgentTabID else {
      workspaceState.launchAgentForPendingReviewPreparation()
      return
    }

    let committedPreparation =
      workspaceState.commitPendingReviewPreparation()
      ?? normalizedPreparation
    launchReview(
      using: agentTabID,
      changeSummary: committedPreparation.draft.renderedSummary
    )
  }

  private func launchFinalize(using agentTabID: UUID) {
    Task {
      defer {
        workspaceState.finishFinalizeFlow()
      }

      guard let action = workspaceState.activeFinalizeAction else { return }

      do {
        let prompt = try workspaceState.prepareFinalizePrompt(
          for: action,
          sourceTabID: agentTabID
        )
        let injected = await GhosttyTerminalView.injectPrompt(prompt, into: agentTabID)
        if !injected {
          workspaceState.cancelFinalizeRequest(for: action)
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

    let topologyPrefix =
      if let label = topology.displayLabel {
        "This worktree is \(label). "
      } else {
        ""
      }

    if topology.needsRebase {
      return
        "\(topologyPrefix)The base branch has moved ahead. Choose how to land this worktree back onto the updated base branch."
    }

    return "\(topologyPrefix)Choose how to land this worktree back onto the base branch."
  }
}
