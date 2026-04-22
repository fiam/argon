import Foundation
import Testing

@testable import Argon

@Suite("WorkspaceState")
struct WorkspaceStateTests {

  @Test("shell tabs stay scoped to their worktree")
  @MainActor
  func shellTabsStayScopedToTheirWorktree() {
    let state = makeState()
    state.openShellTab()

    #expect(state.selectedTerminalTabs.count == 1)
    #expect(state.selectedTerminalTab?.title == "Shell 1")
    #expect(state.selectedTerminalTab?.isSandboxed == true)

    state.selectedWorktreePath = "/tmp/repo/feature"
    state.openShellTab()

    #expect(state.selectedTerminalTabs.count == 1)
    #expect(state.selectedTerminalTab?.worktreePath == "/tmp/repo/feature")
    #expect(state.allTerminalTabs.count == 2)

    state.selectedWorktreePath = "/tmp/repo"
    #expect(state.selectedTerminalTabs.count == 1)
    #expect(state.selectedTerminalTab?.worktreePath == "/tmp/repo")
  }

  @Test("closing a selected tab falls back to a remaining tab")
  @MainActor
  func closingSelectedTabFallsBackToRemainingTab() {
    let state = makeState()
    state.openShellTab()
    state.openShellTab()

    let firstID = state.selectedTerminalTabs[0].id
    let secondID = state.selectedTerminalTabs[1].id
    state.selectTerminalTab(secondID)
    let focusRequestBeforeClose = state.selectedTerminalFocusRequestID
    state.closeTerminalTab(secondID)

    #expect(state.selectedTerminalTabs.count == 1)
    #expect(state.selectedTerminalTab?.id == firstID)
    #expect(state.selectedTerminalFocusRequestID != nil)
    #expect(state.selectedTerminalFocusRequestID != focusRequestBeforeClose)
  }

  @Test("active agent count only includes running agent tabs")
  @MainActor
  func activeAgentCountOnlyIncludesRunningAgentTabs() {
    let state = makeState()
    state.openAgentTab(
      WorkspaceAgentLaunchRequest(
        displayName: "Codex",
        command: "codex --yolo",
        icon: "codex",
        sandboxEnabled: false
      )
    )
    state.openShellTab()

    #expect(state.activeAgentCount(for: "/tmp/repo") == 1)

    state.selectedTerminalTabs.first?.isRunning = false
    #expect(state.activeAgentCount(for: "/tmp/repo") == 0)
  }

  @Test("sandboxed tabs pass their tab id into the launch environment")
  @MainActor
  func sandboxedTabsPassTheirTabIDIntoTheLaunchEnvironment() throws {
    let state = makeState()
    state.openShellTab()
    let shellTab = try #require(state.selectedTerminalTab)
    #expect(
      shellTab.launch.environment["ARGON_TERMINAL_TAB_ID"] == shellTab.id.uuidString.lowercased()
    )

    let agentTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          sandboxEnabled: true
        ))
    )
    #expect(
      agentTab.launch.environment["ARGON_TERMINAL_TAB_ID"] == agentTab.id.uuidString.lowercased()
    )
  }

  @Test("requesting a sandboxed shell prompts before launch when the repo Sandboxfile is missing")
  @MainActor
  func requestingSandboxedShellPromptsBeforeLaunchWhenSandboxfileIsMissing() async {
    let previousLoader = WorkspaceState.sandboxfilePromptLoader
    let previousCreator = WorkspaceState.sandboxfileCreator
    defer {
      WorkspaceState.sandboxfilePromptLoader = previousLoader
      WorkspaceState.sandboxfileCreator = previousCreator
    }

    WorkspaceState.sandboxfilePromptLoader = { repoRoot, launchKind in
      SandboxfilePromptRequest(
        repoRoot: repoRoot,
        repoSandboxfilePath: "\(repoRoot)/Sandboxfile",
        launchKind: launchKind
      )
    }

    let state = makeState()
    state.requestSandboxedShellLaunch()

    #expect(await waitUntil { state.pendingShellSandboxfilePrompt != nil })
    #expect(state.pendingShellSandboxfilePrompt?.launchKind == .shell)
    #expect(state.selectedTerminalTabs.isEmpty)
  }

  @Test("confirming a sandboxed shell prompt creates the Sandboxfile and opens the shell")
  @MainActor
  func confirmingSandboxedShellPromptCreatesSandboxfileAndOpensShell() async {
    let previousLoader = WorkspaceState.sandboxfilePromptLoader
    let previousCreator = WorkspaceState.sandboxfileCreator
    defer {
      WorkspaceState.sandboxfilePromptLoader = previousLoader
      WorkspaceState.sandboxfileCreator = previousCreator
    }

    actor CreatedSandboxfileRecorder {
      private(set) var repoRoot: String?

      func set(repoRoot: String) {
        self.repoRoot = repoRoot
      }
    }

    let createdSandboxfile = CreatedSandboxfileRecorder()
    WorkspaceState.sandboxfilePromptLoader = { repoRoot, launchKind in
      SandboxfilePromptRequest(
        repoRoot: repoRoot,
        repoSandboxfilePath: "\(repoRoot)/Sandboxfile",
        launchKind: launchKind
      )
    }
    WorkspaceState.sandboxfileCreator = { request in
      await createdSandboxfile.set(repoRoot: request.repoRoot)
    }

    let state = makeState()
    state.requestSandboxedShellLaunch()
    #expect(await waitUntil { state.pendingShellSandboxfilePrompt != nil })

    state.confirmSandboxedShellLaunch()

    #expect(await waitUntil { state.selectedTerminalTabs.count == 1 })
    #expect(await createdSandboxfile.repoRoot == "/tmp/repo")
    #expect(state.selectedTerminalTab?.title == "Shell 1")
    #expect(state.pendingShellSandboxfilePrompt == nil)
  }

  @Test("requesting a sandboxed shell opens immediately when no prompt is needed")
  @MainActor
  func requestingSandboxedShellOpensImmediatelyWhenNoPromptIsNeeded() async {
    let previousLoader = WorkspaceState.sandboxfilePromptLoader
    let previousCreator = WorkspaceState.sandboxfileCreator
    defer {
      WorkspaceState.sandboxfilePromptLoader = previousLoader
      WorkspaceState.sandboxfileCreator = previousCreator
    }

    WorkspaceState.sandboxfilePromptLoader = { _, _ in nil }

    let state = makeState()
    state.requestSandboxedShellLaunch()

    #expect(await waitUntil { state.selectedTerminalTabs.count == 1 })
    #expect(state.pendingShellSandboxfilePrompt == nil)
    #expect(state.selectedTerminalTab?.title == "Shell 1")
  }

  @Test("multiple sandboxed shell requests coalesce behind one prompt and restore all tabs")
  @MainActor
  func multipleSandboxedShellRequestsCoalesceBehindOnePrompt() async {
    let previousLoader = WorkspaceState.sandboxfilePromptLoader
    let previousCreator = WorkspaceState.sandboxfileCreator
    defer {
      WorkspaceState.sandboxfilePromptLoader = previousLoader
      WorkspaceState.sandboxfileCreator = previousCreator
    }

    actor CreationRecorder {
      private(set) var count = 0

      func record() {
        count += 1
      }
    }

    let recorder = CreationRecorder()
    WorkspaceState.sandboxfilePromptLoader = { repoRoot, launchKind in
      try? await Task.sleep(for: .milliseconds(50))
      return SandboxfilePromptRequest(
        repoRoot: repoRoot,
        repoSandboxfilePath: "\(repoRoot)/Sandboxfile",
        launchKind: launchKind
      )
    }
    WorkspaceState.sandboxfileCreator = { _ in
      await recorder.record()
    }

    let state = makeState()
    state.requestSandboxedShellLaunch()
    state.requestSandboxedShellLaunch()

    #expect(await waitUntil { state.pendingShellSandboxfilePrompt != nil })
    state.confirmSandboxedShellLaunch()

    #expect(await waitUntil { state.selectedTerminalTabs.count == 2 })
    #expect(await recorder.count == 1)
    #expect(state.selectedTerminalTabs.map(\.title) == ["Shell 1", "Shell 2"])
  }

  @Test("custom agent tabs derive titles from the command and hash duplicate names")
  @MainActor
  func customAgentTabsDeriveTitlesFromCommandName() throws {
    let state = makeState()

    let first = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: commandExecutableName(from: "'/opt/tools/My Agent/bin/codex' --yolo"),
          command: "'/opt/tools/My Agent/bin/codex' --yolo",
          icon: "terminal",
          sandboxEnabled: true,
          useHashedDuplicateSuffix: true
        ))
    )
    let second = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: commandExecutableName(from: "codex exec"),
          command: "codex exec",
          icon: "terminal",
          sandboxEnabled: true,
          useHashedDuplicateSuffix: true
        ))
    )

    #expect(first.title == "codex")
    #expect(second.title == "codex #2")
  }

  @Test("review handoff auto-selects a single running agent tab")
  @MainActor
  func reviewHandoffAutoSelectsSingleRunningAgentTab() throws {
    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          sandboxEnabled: false
        ))
    )

    state.beginReviewLaunchFlow()

    #expect(state.pendingReviewAgentTabID == tab.id)
    #expect(state.isPresentingReviewAgentPicker == false)
    #expect(state.isPresentingAgentLaunchSheet == false)
  }

  @Test("review handoff asks when multiple running agent tabs exist")
  @MainActor
  func reviewHandoffAsksWhenMultipleRunningAgentTabsExist() throws {
    let state = makeState()
    _ = state.openAgentTab(
      WorkspaceAgentLaunchRequest(
        displayName: "Codex",
        command: "codex",
        icon: "codex",
        sandboxEnabled: false
      )
    )
    let second = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Claude Code",
          command: "claude",
          icon: "claude",
          sandboxEnabled: false
        ))
    )

    state.beginReviewLaunchFlow()

    #expect(state.pendingReviewAgentTabID == nil)
    #expect(state.isPresentingReviewAgentPicker == true)
    #expect(state.reviewAgentCandidates.count == 2)

    state.chooseReviewAgentTab(second.id)

    #expect(state.pendingReviewAgentTabID == second.id)
    #expect(state.isPresentingReviewAgentPicker == false)
    #expect(state.reviewAgentCandidates.isEmpty)
  }

  @Test("review handoff falls back to launching a new agent when none are attached")
  @MainActor
  func reviewHandoffFallsBackToLaunchingNewAgentWhenNoneAreAttached() {
    let state = makeState()
    state.openShellTab()

    state.beginReviewLaunchFlow()

    #expect(state.pendingReviewAgentTabID == nil)
    #expect(state.isPresentingAgentLaunchSheet == true)
  }

  @Test("finalize flow auto-selects a single eligible running agent tab")
  @MainActor
  func finalizeFlowAutoSelectsSingleEligibleRunningAgentTab() throws {
    let state = makeState()
    selectFeatureWorktree(in: state)

    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          sandboxEnabled: false
        ))
    )

    state.beginFinalizeFlow(.rebaseAndMergeToBase)

    #expect(state.activeFinalizeAction == .rebaseAndMergeToBase)
    #expect(state.pendingFinalizeAgentTabID == tab.id)
    #expect(state.isPresentingFinalizeAgentPicker == false)
    #expect(state.isPresentingAgentLaunchSheet == false)
  }

  @Test("finalize flow launches a new agent when running tabs lack required writable roots")
  @MainActor
  func finalizeFlowLaunchesNewAgentWhenRunningTabsLackRequiredWritableRoots() {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.openAgentTab(
      WorkspaceAgentLaunchRequest(
        displayName: "Codex",
        command: "codex",
        icon: "codex",
        sandboxEnabled: true
      ))

    state.beginFinalizeFlow(.mergeCommitToBase)

    #expect(state.activeFinalizeAction == .mergeCommitToBase)
    #expect(state.pendingFinalizeAgentTabID == nil)
    #expect(state.isPresentingFinalizeAgentPicker == false)
    #expect(state.isPresentingAgentLaunchSheet == true)
  }

  @Test("finalize flow asks when multiple eligible running agent tabs exist")
  @MainActor
  func finalizeFlowAsksWhenMultipleEligibleRunningAgentTabsExist() {
    let state = makeState()
    selectFeatureWorktree(in: state)
    _ = state.openAgentTab(
      WorkspaceAgentLaunchRequest(
        displayName: "Codex",
        command: "codex",
        icon: "codex",
        sandboxEnabled: false
      )
    )
    let second = state.openAgentTab(
      WorkspaceAgentLaunchRequest(
        displayName: "Claude Code",
        command: "claude",
        icon: "claude",
        sandboxEnabled: false
      )
    )

    state.beginFinalizeFlow(.mergeCommitToBase)

    #expect(state.pendingFinalizeAgentTabID == nil)
    #expect(state.isPresentingFinalizeAgentPicker == true)
    #expect(state.finalizeAgentCandidates.count == 2)

    if let second {
      state.chooseFinalizeAgentTab(second.id)
      #expect(state.pendingFinalizeAgentTabID == second.id)
      #expect(state.isPresentingFinalizeAgentPicker == false)
      #expect(state.finalizeAgentCandidates.isEmpty)
    }
  }

  @Test("rebase only enables when the selected worktree is behind base")
  @MainActor
  func rebaseOnlyEnablesWhenSelectedWorktreeIsBehindBase() {
    let state = makeState()
    selectFeatureWorktree(in: state)

    state.selectedBranchTopology = BranchTopology(aheadCount: 2, behindCount: 0)
    #expect(state.canRebaseSelectedWorktree == false)

    state.selectedBranchTopology = BranchTopology(aheadCount: 2, behindCount: 3)
    #expect(state.canRebaseSelectedWorktree == true)
  }

  @Test("merge back fast-forwards a single ahead commit without showing strategy choices")
  @MainActor
  func mergeBackFastForwardsSingleAheadCommitWithoutShowingStrategyChoices() {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.selectedBranchTopology = BranchTopology(aheadCount: 1, behindCount: 0)

    state.beginMergeBackFlow()

    #expect(state.activeFinalizeAction == .fastForwardToBase)
    #expect(state.isPresentingMergeBackOptions == false)
    #expect(state.mergeBackOptions.isEmpty)
    #expect(state.isPresentingAgentLaunchSheet == true)
  }

  @Test("merge back offers fast-forward and merge commit when branch is linearly ahead")
  @MainActor
  func mergeBackOffersFastForwardAndMergeCommitWhenBranchIsLinearlyAhead() {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.selectedBranchTopology = BranchTopology(aheadCount: 3, behindCount: 0)

    state.beginMergeBackFlow()

    #expect(state.isPresentingMergeBackOptions == true)
    #expect(state.mergeBackOptions == [.mergeCommitToBase, .fastForwardToBase])
    #expect(state.activeFinalizeAction == nil)
  }

  @Test("merge back offers merge, rebase-and-merge, and squash when base moved ahead")
  @MainActor
  func mergeBackOffersMergeRebaseAndSquashWhenBaseMovedAhead() {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.selectedBranchTopology = BranchTopology(aheadCount: 3, behindCount: 2)

    state.beginMergeBackFlow()

    #expect(state.isPresentingMergeBackOptions == true)
    #expect(
      state.mergeBackOptions == [.mergeCommitToBase, .rebaseAndMergeToBase, .squashAndMergeToBase]
    )
    #expect(state.activeFinalizeAction == nil)
  }

  @Test("launching a merge finalizer widens sandbox roots to include the base repo")
  @MainActor
  func launchingMergeFinalizerWidensSandboxRootsToIncludeBaseRepo() async throws {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.activeFinalizeAction = .mergeCommitToBase

    try await state.launchAgent(
      using: WorkspaceAgentLaunchOptions(
        source: .custom(displayName: "codex", command: "codex", icon: "terminal"),
        sandboxEnabled: true
      ))

    let tab = try #require(state.selectedTerminalTab)
    #expect(tab.isSandboxed == true)
    #expect(Set(tab.writableRoots) == Set(["/tmp/repo/feature", "/tmp/repo"]))
    #expect(
      tab.commandDescription.contains(
        "Task: Merge this worktree back into the base branch with a merge commit."
      ))
    #expect(state.activeFinalizeAction == nil)
  }

  @Test("finalize prompts include action, worktree, branch, and base branch context")
  @MainActor
  func finalizePromptIncludesActionContext() throws {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.selectedPullRequestURL =
      "https://github.com/example/repo/compare/main...feature/window?expand=1"

    let prompt = try state.finalizePrompt(for: .openPullRequest)

    #expect(prompt.contains("Task: Open an upstream pull request for this worktree."))
    #expect(prompt.contains("Base worktree: /tmp/repo"))
    #expect(prompt.contains("Linked worktree: /tmp/repo/feature"))
    #expect(prompt.contains("Feature branch: feature/window"))
    #expect(prompt.contains("Base branch: origin/main"))
    #expect(
      prompt.contains(
        "Suggested compare URL: https://github.com/example/repo/compare/main...feature/window?expand=1"
      ))
  }

  @Test("staged review launches activate after the agent sheet dismisses")
  @MainActor
  func stagedReviewLaunchesActivateAfterTheAgentSheetDismisses() {
    let state = makeState()
    let tabID = UUID()
    let target = ReviewTarget(sessionId: "session-123", repoRoot: "/tmp/repo")

    state.stageReviewLaunch(target: target, agentTabID: tabID)
    #expect(state.pendingReviewAgentTabID == nil)

    state.activateStagedReviewLaunch()

    #expect(state.pendingReviewAgentTabID == tabID)
    #expect(state.consumePreparedReviewTarget(for: tabID) == target)
    #expect(state.consumePreparedReviewTarget(for: tabID) == nil)
  }

  @Test("auto-close finished terminals removes shell and agent tabs")
  @MainActor
  func autoCloseFinishedTerminalsRemovesShellAndAgentTabs() async throws {
    let state = makeState()
    state.openShellTab()
    let shellID = try #require(state.selectedTerminalTab?.id)

    state.handleTerminalExit(shellID, exitBehavior: .autoClose)
    await Task.yield()

    #expect(state.selectedTerminalTabs.isEmpty)

    state.openAgentTab(
      WorkspaceAgentLaunchRequest(
        displayName: "Codex",
        command: "codex",
        icon: "codex",
        sandboxEnabled: false
      )
    )
    let agentID = try #require(state.selectedTerminalTab?.id)

    state.handleTerminalExit(agentID, exitBehavior: .autoClose)
    await Task.yield()

    #expect(state.selectedTerminalTabs.isEmpty)
  }

  @Test("keep-open finished terminals preserves exited tabs")
  @MainActor
  func keepOpenFinishedTerminalsPreservesExitedTabs() async throws {
    let state = makeState()
    state.openAgentTab(
      WorkspaceAgentLaunchRequest(
        displayName: "Codex",
        command: "codex",
        icon: "codex",
        sandboxEnabled: false
      )
    )
    let agentID = try #require(state.selectedTerminalTab?.id)

    state.handleTerminalExit(agentID, exitBehavior: .keepOpen)
    await Task.yield()

    #expect(state.selectedTerminalTabs.count == 1)
    #expect(state.selectedTerminalTab?.id == agentID)
    #expect(state.selectedTerminalTab?.isRunning == false)
  }

  @Test("opening and selecting tabs requests terminal focus")
  @MainActor
  func openingAndSelectingTabsRequestsTerminalFocus() {
    let state = makeState()

    #expect(state.selectedTerminalFocusRequestID == nil)

    state.openShellTab()
    let firstFocusRequest = state.selectedTerminalFocusRequestID
    #expect(firstFocusRequest != nil)

    state.openShellTab()
    let secondFocusRequest = state.selectedTerminalFocusRequestID
    #expect(secondFocusRequest != nil)
    #expect(secondFocusRequest != firstFocusRequest)

    let firstTabID = state.selectedTerminalTabs[0].id
    state.selectTerminalTab(firstTabID)

    #expect(state.selectedTerminalTab?.id == firstTabID)
    #expect(state.selectedTerminalFocusRequestID != nil)
    #expect(state.selectedTerminalFocusRequestID != secondFocusRequest)
  }

  @Test("terminal attention marks tabs and clears when selected")
  @MainActor
  func terminalAttentionMarksTabsAndClearsWhenSelected() throws {
    let state = makeState()
    state.openShellTab()
    let tab = try #require(state.selectedTerminalTab)

    #expect(state.worktreeNeedsAttention(for: "/tmp/repo") == false)
    #expect(tab.hasAttention == false)

    state.markTerminalNeedsAttention(tab.id)

    #expect(tab.hasAttention == true)
    #expect(state.worktreeNeedsAttention(for: "/tmp/repo") == true)

    state.selectTerminalTab(tab.id)

    #expect(tab.hasAttention == false)
    #expect(state.worktreeNeedsAttention(for: "/tmp/repo") == false)
  }

  @Test("focusTerminal switches worktree, focuses tab, and clears attention")
  @MainActor
  func focusTerminalSwitchesWorktreeFocusesTabAndClearsAttention() throws {
    let state = makeState()
    state.openShellTab()
    let baseTab = try #require(state.selectedTerminalTab)

    selectFeatureWorktree(in: state)
    state.openShellTab()
    let featureTab = try #require(state.selectedTerminalTab)

    state.markTerminalNeedsAttention(baseTab.id)
    state.markTerminalNeedsAttention(featureTab.id)

    state.focusTerminal(tabID: baseTab.id, in: "/tmp/repo")

    #expect(state.selectedWorktreePath == "/tmp/repo")
    #expect(state.selectedTerminalTab?.id == baseTab.id)
    #expect(baseTab.hasAttention == false)
    #expect(state.worktreeNeedsAttention(for: "/tmp/repo") == false)
    #expect(state.worktreeNeedsAttention(for: "/tmp/repo/feature") == true)
  }

  @Test("default shell tabs use sandbox exec and expose sandbox identity")
  @MainActor
  func defaultShellTabsUseSandboxExecAndExposeSandboxIdentity() {
    let state = makeState()

    state.openShellTab()

    let tab = state.selectedTerminalTab
    #expect(tab?.title == "Shell 1")
    #expect(tab?.isSandboxed == true)
    #expect(tab?.commandDescription.contains("Sandboxed") == true)
    #expect(tab?.launch.processSpec.executable == ArgonCLI.cliPath())
    #expect(tab?.launch.processSpec.args.starts(with: ["sandbox", "exec"]) == true)
    #expect(tab?.launch.processSpec.args.contains("/tmp/repo") == true)
  }

  @Test("privileged shell tabs bypass sandbox exec and use privileged naming")
  @MainActor
  func privilegedShellTabsBypassSandboxExecAndUsePrivilegedNaming() {
    let state = makeState()

    state.openShellTab(sandboxed: false)

    let tab = state.selectedTerminalTab
    #expect(tab?.title == "Privileged Shell 1")
    #expect(tab?.isSandboxed == false)
    #expect(tab?.commandDescription.contains("Sandboxed") == false)
    #expect(tab?.launch.processSpec.executable == UserShell.resolvedPath())
  }

  @Test("window title includes selected worktree label")
  @MainActor
  func windowTitleIncludesSelectedWorktreeLabel() {
    let state = makeState()

    #expect(state.windowTitle == "Argon — repo — main")

    state.selectedWorktreePath = "/tmp/repo/feature"

    #expect(state.windowTitle == "Argon — repo — feature/window")
  }

  @Test("persisted snapshots restore tabs lazily for the selected worktree")
  @MainActor
  func persistedSnapshotsRestoreTabsLazilyForSelectedWorktree() async throws {
    let state = makeState()
    state.openShellTab()

    selectFeatureWorktree(in: state)
    let codexTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "/bin/sh -lc 'printf restored\\n'",
          icon: "codex",
          sandboxEnabled: true
        ))
    )
    state.openShellTab(sandboxed: false)
    state.selectTerminalTab(codexTab.id)

    let snapshot = state.persistedWindowSnapshot
    #expect(snapshot.target.showsLinkedWorktreeWarning == false)

    let restoredState = makeState()
    restoredState.applyPersistedWindowSnapshot(snapshot)

    #expect(restoredState.selectedWorktreePath == "/tmp/repo/feature")
    #expect(restoredState.selectedTerminalTabs.isEmpty)
    #expect(restoredState.allTerminalTabs.isEmpty)

    restoredState.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(await waitUntil { !restoredState.selectedTerminalTabs.isEmpty })

    #expect(restoredState.selectedTerminalTabs.map(\.title) == ["Codex", "Privileged Shell 1"])
    #expect(restoredState.selectedTerminalTab?.id == codexTab.id)
    #expect(
      restoredState.selectedTerminalTabs.allSatisfy { $0.worktreePath == "/tmp/repo/feature" })
    #expect(restoredState.terminalTabsByWorktreePath["/tmp/repo"] == nil)

    restoredState.prepareSelectionLoading(for: "/tmp/repo")
    #expect(await waitUntil { restoredState.terminalTabsByWorktreePath["/tmp/repo"] != nil })

    #expect(restoredState.terminalTabsByWorktreePath["/tmp/repo"]?.map(\.title) == ["Shell 1"])
    #expect(restoredState.launchWarningMessage == nil)
  }

  @Test("lazy restore skips missing agent commands and shows a restore toast")
  @MainActor
  func lazyRestoreSkipsMissingAgentCommandsAndShowsRestoreToast() async {
    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Shell 1",
            commandDescription: "Sandboxed /bin/zsh",
            kind: .shell,
            createdAt: Date(timeIntervalSince1970: 1),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"]
          ),
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Missing Agent",
            commandDescription: "/definitely/missing/agent --yolo",
            kind: .agent(profileName: "Missing Agent", icon: "terminal"),
            createdAt: Date(timeIntervalSince1970: 2),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"]
          ),
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)

    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(
      await waitUntil { !state.selectedTerminalTabs.isEmpty || state.restoreFailureMessage != nil })

    #expect(state.selectedTerminalTabs.map(\.title) == ["Shell 1"])
    #expect(state.selectedTerminalTab?.title == "Shell 1")
    #expect(state.restoreFailureMessage?.contains("1 agent tab") == true)
    #expect(state.restoreFailureMessage?.contains("feature/window") == true)
  }

  @Test("opening a tab while lazy restore is in flight preserves the new tab")
  @MainActor
  func openingTabDuringLazyRestorePreservesNewTab() async {
    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Restored Shell",
            commandDescription: "Sandboxed /bin/zsh",
            kind: .shell,
            createdAt: Date(timeIntervalSince1970: 1),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"]
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)

    WorkspaceState.tabRestoreTestDelay = .milliseconds(150)
    defer { WorkspaceState.tabRestoreTestDelay = nil }

    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    state.openShellTab(sandboxed: false)

    #expect(state.selectedTerminalTab?.title == "Privileged Shell 1")
    #expect(
      await waitUntil(timeout: .seconds(2)) {
        state.selectedTerminalTabs.count == 2
      }
    )
    #expect(state.selectedTerminalTabs.map(\.title) == ["Restored Shell", "Privileged Shell 1"])
    #expect(state.selectedTerminalTab?.title == "Privileged Shell 1")
  }

  @Test("suggested worktree path uses configured root and repo subtree")
  @MainActor
  func suggestedWorktreePathUsesConfiguredRootAndRepoSubtree() {
    let state = makeState(worktreeRootPath: "/tmp/worktrees")

    let suggestedPath = state.suggestedWorktreePath(branchName: "feature/window polish")

    #expect(suggestedPath == "/tmp/worktrees/tmp/repo/feature-window-polish")
  }

  @Test("unchanged worktree paths do not trigger an inventory reload")
  func unchangedWorktreePathsDoNotTriggerAnInventoryReload() {
    let currentWorktrees = [
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      ),
      DiscoveredWorktree(
        path: "/tmp/repo/feature",
        branchName: "feature/original",
        headSHA: "def456",
        isBaseWorktree: false,
        isDetached: false
      ),
    ]
    let discoveredWorktrees = [
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "999999",
        isBaseWorktree: true,
        isDetached: false
      ),
      DiscoveredWorktree(
        path: "/tmp/repo/feature",
        branchName: "feature/renamed",
        headSHA: "000000",
        isBaseWorktree: false,
        isDetached: false
      ),
    ]

    #expect(
      WorkspaceState.shouldReloadWorktreeInventory(
        currentWorktrees: currentWorktrees,
        discoveredWorktrees: discoveredWorktrees
      ) == false
    )
  }

  @Test("inventory updates keep the selected worktree when its path still exists")
  @MainActor
  func inventoryUpdatesKeepTheSelectedWorktreeWhenItsPathStillExists() throws {
    let state = makeState()
    state.openShellTab()
    state.selectedWorktreePath = "/tmp/repo/feature"
    let selectedTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          sandboxEnabled: true
        ))
    )

    state.applyDiscoveredWorktreeInventory([
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      ),
      DiscoveredWorktree(
        path: "/tmp/repo/feature",
        branchName: "feature/window",
        headSHA: "def456",
        isBaseWorktree: false,
        isDetached: false
      ),
      DiscoveredWorktree(
        path: "/tmp/repo/review",
        branchName: "review/comments",
        headSHA: "ghi789",
        isBaseWorktree: false,
        isDetached: false
      ),
    ])

    #expect(state.selectedWorktreePath == "/tmp/repo/feature")
    #expect(state.selectedTerminalTab?.id == selectedTab.id)
    #expect(state.allTerminalTabs.count == 2)
    #expect(state.worktrees.map(\.path) == ["/tmp/repo", "/tmp/repo/feature", "/tmp/repo/review"])
  }

  @Test("inventory updates fall back when the selected worktree disappears")
  @MainActor
  func inventoryUpdatesFallBackWhenTheSelectedWorktreeDisappears() {
    let state = makeState()
    state.selectedWorktreePath = "/tmp/repo/feature"
    state.openShellTab()

    state.applyDiscoveredWorktreeInventory([
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      )
    ])

    #expect(state.selectedWorktreePath == "/tmp/repo")
    #expect(state.allTerminalTabs.isEmpty)
    #expect(state.worktrees.map(\.path) == ["/tmp/repo"])
  }

  @Test("restored selections fall back to the base worktree when the selected worktree was deleted")
  @MainActor
  func restoredSelectionsFallBackToTheBaseWorktreeWhenSelectedWorktreeWasDeleted() {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.openAgentTab(
      WorkspaceAgentLaunchRequest(
        displayName: "Codex",
        command: "codex --yolo",
        icon: "codex",
        sandboxEnabled: true
      )
    )

    let snapshot = state.persistedWindowSnapshot

    let restoredState = makeState()
    restoredState.applyPersistedWindowSnapshot(snapshot)
    restoredState.applyDiscoveredWorktreeInventory([
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      )
    ])

    #expect(restoredState.selectedWorktreePath == "/tmp/repo")
    #expect(restoredState.selectedTerminalTabs.isEmpty)
    #expect(restoredState.allTerminalTabs.isEmpty)
    #expect(restoredState.worktrees.map(\.path) == ["/tmp/repo"])
  }

  @Test("deleted worktrees drop cached tabs so a reused path does not resurrect old state")
  @MainActor
  func deletedWorktreesDropCachedTabsForReusedPaths() async {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.openShellTab()

    let snapshot = state.persistedWindowSnapshot
    let restoredState = makeState()
    restoredState.applyPersistedWindowSnapshot(snapshot)

    restoredState.applyDiscoveredWorktreeInventory([
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      )
    ])

    #expect(restoredState.allTerminalTabs.isEmpty)

    restoredState.applyDiscoveredWorktreeInventory([
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      ),
      DiscoveredWorktree(
        path: "/tmp/repo/feature",
        branchName: "feature/window",
        headSHA: "def456",
        isBaseWorktree: false,
        isDetached: false
      ),
    ])
    restoredState.prepareSelectionLoading(for: "/tmp/repo/feature")

    #expect(await waitUntil { restoredState.normalizedSelectedWorktreePath == "/tmp/repo/feature" })
    #expect(restoredState.selectedTerminalTabs.isEmpty)
    #expect(restoredState.allTerminalTabs.isEmpty)
  }

  @Test("prepareWorktreeRemoval rejects the base worktree")
  @MainActor
  func prepareWorktreeRemovalRejectsTheBaseWorktree() async throws {
    let state = makeState()
    let baseWorktree = try #require(state.worktrees.first { $0.isBaseWorktree })

    await #expect(throws: GitService.GitError.self) {
      try await state.prepareWorktreeRemoval(for: baseWorktree)
    }
  }

  @Test("clean empty branches skip worktree removal confirmation")
  func cleanEmptyBranchesSkipWorktreeRemovalConfirmation() {
    let request = WorktreeRemovalRequest(
      worktreePath: "/tmp/repo/feature",
      displayName: "feature/empty",
      branchName: "feature/empty",
      hasUncommittedChanges: false,
      canDeleteBranch: true,
      branchComparisonBaseRef: "main",
      branchHasUniqueCommits: false
    )

    #expect(request.shouldSkipConfirmation == true)
    #expect(request.defaultDeletesBranch == true)
  }

  @Test("refreshing the selected worktree updates the visible diff state")
  @MainActor
  func refreshingSelectedWorktreeUpdatesVisibleDiffState() {
    let state = makeState()
    state.selectedWorktreePath = "/tmp/repo/feature"

    let refreshed = RefreshedWorktree(
      summary: WorktreeDiffSummary(fileCount: 1, addedLineCount: 3, removedLineCount: 2),
      files: [
        FileDiff(
          oldPath: "Sources/App.swift",
          newPath: "Sources/App.swift",
          hunks: [],
          addedCount: 3,
          removedCount: 2
        )
      ],
      diffStat: "1 file changed, 3 insertions(+), 2 deletions(-)",
      pullRequestURL: "https://example.com/pr",
      reviewTarget: ResolvedTarget(
        mode: .branch,
        baseRef: "origin/main",
        headRef: "feature/window",
        mergeBaseSha: "abc123"
      ),
      branchTopology: BranchTopology(aheadCount: 2, behindCount: 1),
      hasConflicts: true
    )

    state.applyRefreshedWorktree(refreshed, for: "/tmp/repo/feature")

    #expect(state.summary(for: "/tmp/repo/feature").fileCount == 1)
    #expect(state.selectedSummary.fileCount == 1)
    #expect(state.selectedFiles.count == 1)
    #expect(state.selectedDiffStat == refreshed.diffStat)
    #expect(state.selectedPullRequestURL == refreshed.pullRequestURL)
    #expect(state.selectedReviewTarget?.headRef == "feature/window")
    #expect(state.hasConflicts(for: "/tmp/repo/feature") == true)
  }

  @Test("preparing a new selection clears stale details and marks the inspector as loading")
  @MainActor
  func preparingNewSelectionClearsStaleDetailsAndMarksInspectorLoading() {
    let state = makeState()
    state.selectedSummary = WorktreeDiffSummary(
      fileCount: 2,
      addedLineCount: 5,
      removedLineCount: 1
    )
    state.selectedFiles = [
      FileDiff(
        oldPath: "README.md",
        newPath: "README.md",
        hunks: [],
        addedCount: 1,
        removedCount: 0
      )
    ]
    state.selectedDiffStat = "2 files changed"
    state.selectedPullRequestURL = "https://example.com/pr"
    state.selectedReviewTarget = ResolvedTarget(
      mode: .branch,
      baseRef: "origin/main",
      headRef: "main",
      mergeBaseSha: "abc123"
    )
    state.worktreeSummaries["/tmp/repo/feature"] = WorktreeDiffSummary(
      fileCount: 1,
      addedLineCount: 3,
      removedLineCount: 2
    )

    state.prepareSelectionLoading(for: "/tmp/repo/feature")

    #expect(state.selectedWorktreePath == "/tmp/repo/feature")
    #expect(state.selectedSummary.fileCount == 1)
    #expect(state.selectedFiles.isEmpty)
    #expect(state.selectedDiffStat.isEmpty)
    #expect(state.selectedPullRequestURL == nil)
    #expect(state.selectedReviewTarget == nil)
    #expect(state.isLoadingSelectionDetails == true)
  }

  @Test("refreshing an unselected worktree keeps the current detail view intact")
  @MainActor
  func refreshingUnselectedWorktreeDoesNotReplaceCurrentDetailView() {
    let state = makeState()
    state.selectedSummary = WorktreeDiffSummary(
      fileCount: 2,
      addedLineCount: 4,
      removedLineCount: 1
    )
    state.selectedFiles = [
      FileDiff(
        oldPath: "README.md",
        newPath: "README.md",
        hunks: [],
        addedCount: 1,
        removedCount: 0
      )
    ]
    state.selectedDiffStat = "2 files changed"

    let refreshed = RefreshedWorktree(
      summary: WorktreeDiffSummary(fileCount: 1, addedLineCount: 1, removedLineCount: 0),
      files: [
        FileDiff(oldPath: "b.txt", newPath: "b.txt", hunks: [], addedCount: 1, removedCount: 0)
      ],
      diffStat: "1 file changed",
      pullRequestURL: nil,
      reviewTarget: nil,
      branchTopology: nil,
      hasConflicts: false
    )

    state.applyRefreshedWorktree(refreshed, for: "/tmp/repo/feature")

    #expect(state.summary(for: "/tmp/repo/feature").fileCount == 1)
    #expect(state.selectedSummary.fileCount == 2)
    #expect(state.selectedFiles.first?.displayPath == "README.md")
    #expect(state.selectedDiffStat == "2 files changed")
  }

  @Test("review session close notifications refresh workspace review snapshots")
  @MainActor
  func reviewSessionCloseNotificationsRefreshWorkspaceReviewSnapshots() async throws {
    let storageRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    let originalArgonHome = ProcessInfo.processInfo.environment["ARGON_HOME"]
    defer {
      if let originalArgonHome {
        setenv("ARGON_HOME", originalArgonHome, 1)
      } else {
        unsetenv("ARGON_HOME")
      }
      try? FileManager.default.removeItem(at: storageRoot)
    }

    setenv("ARGON_HOME", storageRoot.path, 1)

    let state = makeState()
    let sessionsDirectory =
      storageRoot
      .appendingPathComponent("sessions")
      .appendingPathComponent("fixture-repo")
    try FileManager.default.createDirectory(
      at: sessionsDirectory,
      withIntermediateDirectories: true
    )

    let sessionURL = sessionsDirectory.appendingPathComponent("session.json")
    try write(
      session: makeReviewSession(
        repoRoot: "/tmp/repo",
        status: .awaitingAgent,
        updatedAt: Date(timeIntervalSince1970: 10)
      ),
      to: sessionURL
    )
    state.refreshReviewSnapshot(for: "/tmp/repo")
    #expect(state.reviewSnapshot(for: "/tmp/repo")?.status == .awaitingAgent)

    try write(
      session: makeReviewSession(
        repoRoot: "/tmp/repo",
        status: .closed,
        updatedAt: Date(timeIntervalSince1970: 20)
      ),
      to: sessionURL
    )
    ReviewSessionLifecycle.postSessionClosed(repoRoot: "/tmp/repo")
    await Task.yield()

    #expect(state.reviewSnapshot(for: "/tmp/repo")?.status == .closed)
  }

  @Test("lazy restore maps Codex tabs to distinct sessions in one worktree")
  @MainActor
  func lazyRestoreMapsMultipleCodexTabsToDistinctSessions() async {
    WorkspaceState.sessionRecordsProvider = {
      [
        AgentSessionRecord(
          provider: .codex,
          sessionID: "11111111-1111-1111-1111-111111111111",
          cwd: "/tmp/repo/feature",
          startedAt: Date(timeIntervalSince1970: 11)
        ),
        AgentSessionRecord(
          provider: .codex,
          sessionID: "22222222-2222-2222-2222-222222222222",
          cwd: "/tmp/repo/feature",
          startedAt: Date(timeIntervalSince1970: 21)
        ),
      ]
    }
    defer { WorkspaceState.sessionRecordsProvider = nil }

    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            createdAt: Date(timeIntervalSince1970: 10),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"]
          ),
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex 2",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            createdAt: Date(timeIntervalSince1970: 20),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"]
          ),
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)

    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(await waitUntil { state.selectedTerminalTabs.count == 2 })

    let tabsByTitle = Dictionary(
      uniqueKeysWithValues: state.selectedTerminalTabs.map {
        ($0.title, $0)
      })
    let firstTab = tabsByTitle["Codex"]
    let secondTab = tabsByTitle["Codex 2"]

    #expect(firstTab?.resumeSessionID == "11111111-1111-1111-1111-111111111111")
    #expect(secondTab?.resumeSessionID == "22222222-2222-2222-2222-222222222222")
    #expect(
      firstTab?.launch.processSpec.args.last?.contains(
        "resume '11111111-1111-1111-1111-111111111111'") == true)
    #expect(
      secondTab?.launch.processSpec.args.last?.contains(
        "resume '22222222-2222-2222-2222-222222222222'"
      ) == true
    )
  }

  @Test("lazy restore falls back to original command when no resume session is available")
  @MainActor
  func lazyRestoreFallsBackToOriginalCommandWhenNoResumeSessionIsAvailable() async {
    WorkspaceState.sessionRecordsProvider = { [] }
    defer { WorkspaceState.sessionRecordsProvider = nil }

    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            createdAt: Date(timeIntervalSince1970: 30),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"]
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)

    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(await waitUntil { state.selectedTerminalTabs.count == 1 })

    let tab = state.selectedTerminalTabs.first
    #expect(tab?.resumeSessionID == nil)
    #expect(tab?.launch.processSpec.args.last == "codex --yolo")
  }

  @Test("persisted snapshots do not serialize resume templates per tab")
  @MainActor
  func persistedSnapshotsDoNotSerializeResumeTemplatesPerTab() throws {
    let state = makeState()
    _ = state.openAgentTab(
      WorkspaceAgentLaunchRequest(
        displayName: "Codex",
        command: "codex --yolo",
        icon: "codex",
        sandboxEnabled: true,
        resumeArgumentTemplate: "resume {{session_id}}"
      )
    )

    let snapshot = state.persistedWindowSnapshot
    let data = try JSONEncoder().encode(snapshot)
    let json = String(decoding: data, as: UTF8.self)

    #expect(!json.contains("resumeArgumentTemplate"))
  }

  @MainActor
  private func makeState(worktreeRootPath: String = "/tmp/default-worktrees") -> WorkspaceState {
    let target = WorkspaceTarget(
      repoRoot: "/tmp/repo",
      repoCommonDir: "/tmp/repo/.git",
      selectedWorktreePath: "/tmp/repo"
    )
    WorktreeMergeStrategySettings.setStrategy(.mergeCommit, for: target.repoRoot)
    let state = WorkspaceState(target: target) { worktreeRootPath }
    state.worktrees = [
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      ),
      DiscoveredWorktree(
        path: "/tmp/repo/feature",
        branchName: "feature/window",
        headSHA: "def456",
        isBaseWorktree: false,
        isDetached: false
      ),
    ]
    state.selectedWorktreePath = "/tmp/repo"
    return state
  }

  @MainActor
  private func selectFeatureWorktree(in state: WorkspaceState) {
    state.selectedWorktreePath = "/tmp/repo/feature"
    state.selectedReviewTarget = ResolvedTarget(
      mode: .branch,
      baseRef: "origin/main",
      headRef: "feature/window",
      mergeBaseSha: "abc123"
    )
    state.selectedBranchTopology = BranchTopology(aheadCount: 2, behindCount: 0)
  }

  private func makeReviewSession(
    repoRoot: String,
    status: SessionStatus,
    updatedAt: Date
  ) -> ReviewSession {
    ReviewSession(
      id: UUID(),
      repoRoot: repoRoot,
      mode: .branch,
      baseRef: "origin/main",
      headRef: "feature/workspace",
      mergeBaseSha: "abc123",
      changeSummary: "Add workspace tabs",
      status: status,
      threads: [],
      decision: nil,
      agentLastSeenAt: nil,
      createdAt: updatedAt,
      updatedAt: updatedAt
    )
  }

  private func write(session: ReviewSession, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(session)
    try data.write(to: url)
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
      if await condition() {
        return true
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    return await condition()
  }
}
