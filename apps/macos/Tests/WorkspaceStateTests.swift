import Foundation
import Testing

@testable import Argon

@Suite("WorkspaceState", .serialized)
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

  @Test("closing the selected terminal tab uses the active selection")
  @MainActor
  func closingSelectedTerminalTabUsesActiveSelection() {
    let state = makeState()

    #expect(state.closeSelectedTerminalTab() == false)

    state.openShellTab()
    state.openShellTab()

    let firstID = state.selectedTerminalTabs[0].id
    let secondID = state.selectedTerminalTabs[1].id
    state.selectTerminalTab(secondID)

    #expect(state.closeSelectedTerminalTab() == true)
    #expect(state.selectedTerminalTabs.map(\.id) == [firstID])
    #expect(state.selectedTerminalTab?.id == firstID)
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
    #expect(state.runningAgentCount == 1)

    state.selectedTerminalTabs.first?.isRunning = false
    #expect(state.activeAgentCount(for: "/tmp/repo") == 0)
    #expect(state.runningAgentCount == 0)
  }

  @Test("agent title changes mark the tab thinking until the idle timeout")
  @MainActor
  func agentTitleChangesMarkTheTabThinkingUntilIdleTimeout() async throws {
    let previousTimeout = WorkspaceState.agentThinkingIdleTimeout
    WorkspaceState.agentThinkingIdleTimeout = .milliseconds(40)
    defer {
      WorkspaceState.agentThinkingIdleTimeout = previousTimeout
    }

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

    state.recordTerminalTitleChange("working", for: tab.id)

    #expect(tab.agentActivityState == .thinking)
    #expect(
      state.agentActivitySummary(for: "/tmp/repo")
        == WorktreeAgentActivitySummary(
          waitingForHumanCount: 0,
          thinkingCount: 1,
          runningAgentCount: 1
        )
    )
    #expect(await waitUntil { tab.agentActivityState == .idle })
  }

  @Test("blank agent title values do not clear thinking immediately")
  @MainActor
  func blankAgentTitleValuesDoNotClearThinkingImmediately() async throws {
    let previousTimeout = WorkspaceState.agentThinkingIdleTimeout
    WorkspaceState.agentThinkingIdleTimeout = .milliseconds(80)
    defer {
      WorkspaceState.agentThinkingIdleTimeout = previousTimeout
    }

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

    state.recordTerminalTitleChange("working", for: tab.id)
    state.recordTerminalTitleChange("  ", for: tab.id)

    #expect(tab.agentActivityState == .thinking)
    try await Task.sleep(for: .milliseconds(20))
    #expect(tab.agentActivityState == .thinking)
    #expect(await waitUntil { tab.agentActivityState == .idle })
  }

  @Test("repeated agent title values do not refresh thinking")
  @MainActor
  func repeatedAgentTitleValuesDoNotRefreshThinking() async throws {
    let previousTimeout = WorkspaceState.agentThinkingIdleTimeout
    WorkspaceState.agentThinkingIdleTimeout = .milliseconds(40)
    defer {
      WorkspaceState.agentThinkingIdleTimeout = previousTimeout
    }

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

    state.recordTerminalTitleChange("working", for: tab.id)
    #expect(await waitUntil { tab.agentActivityState == .idle })

    state.recordTerminalTitleChange("working", for: tab.id)

    #expect(tab.agentActivityState == .idle)
  }

  @Test("desktop notifications mark agent tabs waiting for human")
  @MainActor
  func desktopNotificationsMarkAgentTabsWaitingForHuman() throws {
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

    state.markAgentWaitingForHuman(tab.id)

    #expect(tab.agentActivityState == .waitingForHuman)
    #expect(
      state.agentActivitySummary(for: "/tmp/repo")
        == WorktreeAgentActivitySummary(
          waitingForHumanCount: 1,
          thinkingCount: 0,
          runningAgentCount: 1
        )
    )

    state.selectTerminalTab(tab.id)

    #expect(tab.agentActivityState == .idle)
  }

  @Test("shell tabs do not participate in agent activity")
  @MainActor
  func shellTabsDoNotParticipateInAgentActivity() throws {
    let state = makeState()
    state.openShellTab()
    let tab = try #require(state.selectedTerminalTab)

    state.recordTerminalTitleChange("busy", for: tab.id)
    state.markAgentWaitingForHuman(tab.id)

    #expect(tab.agentActivityState == .idle)
    #expect(state.agentActivitySummary(for: "/tmp/repo") == .empty)
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

  @Test("review preparation auto-selects a single running agent tab")
  @MainActor
  func reviewPreparationAutoSelectsSingleRunningAgentTab() throws {
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

    #expect(state.pendingReviewPreparation?.selectedAgentTabID == tab.id)
    #expect(state.isPresentingReviewPreparationSheet == true)
    #expect(state.isPresentingAgentLaunchSheet == false)
  }

  @Test("review preparation allows manual choice when multiple running agent tabs exist")
  @MainActor
  func reviewPreparationAllowsManualChoiceWhenMultipleRunningAgentTabsExist() throws {
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

    #expect(state.pendingReviewPreparation?.selectedAgentTabID == nil)
    #expect(state.isPresentingReviewPreparationSheet == true)
    #expect(state.reviewAgentCandidates.count == 2)
    state.updatePendingReviewPreparation(
      WorkspaceReviewPreparation(
        worktreePath: "/tmp/repo",
        draft: .empty,
        selectedAgentTabID: second.id
      )
    )
    #expect(state.pendingReviewPreparation?.selectedAgentTabID == second.id)
  }

  @Test("review preparation allows manual summary when no running agent tabs exist")
  @MainActor
  func reviewPreparationAllowsManualSummaryWhenNoRunningAgentTabsExist() {
    let state = makeState()
    state.openShellTab()

    state.beginReviewLaunchFlow()

    #expect(state.pendingReviewPreparation?.selectedAgentTabID == nil)
    #expect(state.isPresentingReviewPreparationSheet == true)
    #expect(state.isPresentingAgentLaunchSheet == false)
    #expect(state.reviewAgentCandidates.isEmpty)
  }

  @Test("review preparation persists the normalized summary draft")
  @MainActor
  func reviewPreparationPersistsTheNormalizedSummaryDraft() {
    let state = makeState()
    state.beginReviewLaunchFlow()
    state.updatePendingReviewPreparation(
      WorkspaceReviewPreparation(
        worktreePath: "/tmp/repo",
        draft: WorkspaceReviewSummaryDraft(
          title: "  Tighten review flow  ",
          summary: "  Added a summary-first review path.  ",
          testing: "  make check  ",
          risks: "  Need more UI coverage  "
        ),
        selectedAgentTabID: nil
      )
    )

    let committed = state.commitPendingReviewPreparation()

    #expect(committed?.draft.title == "Tighten review flow")
    #expect(
      state.reviewSummaryDraft(for: "/tmp/repo")?.summary == "Added a summary-first review path.")
    #expect(state.selectedReviewSummaryText?.contains("Testing:\nmake check") == true)
  }

  @Test("typed review summary responses update the persisted draft")
  @MainActor
  func typedReviewSummaryResponsesUpdateThePersistedDraft() async throws {
    let state = makeState()
    selectFeatureWorktree(in: state)

    let prompt = try state.prepareReviewSummaryPrompt(
      for: "/tmp/repo/feature",
      agentTabID: UUID()
    )
    let pending = try #require(
      state.pendingReviewSummaryRequest(for: "/tmp/repo/feature")
    )

    #expect(prompt.contains(pending.responseFilePath))
    #expect(state.isRequestingReviewSummary(for: "/tmp/repo/feature"))

    let response = WorkspaceAgentControlResponse.reviewSummary(
      requestID: pending.request.id,
      status: .success,
      message: "Summary drafted from the current diff.",
      draft: WorkspaceReviewSummaryDraft(
        title: "Review workspace",
        summary: "Summarize the diff before review.",
        testing: "make check",
        risks: "Need more UI coverage."
      )
    )
    try write(agentControlResponse: response, to: pending.responseFilePath)

    #expect(
      await waitUntil {
        state.reviewSummaryDraft(for: "/tmp/repo/feature")?.title == "Review workspace"
      })
    #expect(state.isRequestingReviewSummary(for: "/tmp/repo/feature") == false)
    #expect(state.launchWarningMessage == "Summary drafted from the current diff.")
  }

  @Test("launching an agent from review preparation stages the draft and opens the agent sheet")
  @MainActor
  func launchingAgentFromReviewPreparationStagesTheDraftAndOpensTheAgentSheet() {
    let state = makeState()
    state.beginReviewLaunchFlow()
    state.updatePendingReviewPreparation(
      WorkspaceReviewPreparation(
        worktreePath: "/tmp/repo",
        draft: WorkspaceReviewSummaryDraft(
          title: "Review workspace",
          summary: "Summarize the diff before review.",
          testing: "",
          risks: ""
        ),
        selectedAgentTabID: nil
      )
    )

    state.launchAgentForPendingReviewPreparation()

    #expect(state.isPresentingReviewPreparationSheet == false)
    #expect(state.isPresentingAgentLaunchSheet == true)
    #expect(state.reviewSummaryDraft(for: "/tmp/repo")?.title == "Review workspace")
  }

  @Test("review snapshots are hidden when the selected target changes")
  @MainActor
  func reviewSnapshotsAreHiddenWhenTheSelectedTargetChanges() {
    let state = makeState()
    selectFeatureWorktree(in: state)
    let updatedAt = Date(timeIntervalSince1970: 1_717_171_717)
    let staleSession = ReviewSession(
      id: UUID(),
      repoRoot: "/tmp/repo/feature",
      mode: .branch,
      baseRef: "origin/main",
      headRef: "feature/old-window",
      mergeBaseSha: "old123",
      changeSummary: "Old summary",
      status: .approved,
      threads: [],
      decision: ReviewDecision(
        outcome: .approved,
        summary: "Old decision",
        createdAt: updatedAt
      ),
      agentLastSeenAt: nil,
      createdAt: updatedAt,
      updatedAt: updatedAt
    )
    state.reviewSnapshotsByWorktreePath["/tmp/repo/feature"] = WorkspaceReviewSnapshot(
      session: staleSession
    )

    #expect(state.reviewSnapshot(for: "/tmp/repo/feature") == nil)
    #expect(state.selectedReviewSnapshot == nil)
    #expect(state.selectedReviewSummaryText == nil)
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
  func mergeBackFastForwardsSingleAheadCommitWithoutShowingStrategyChoices() async {
    let restoreMergeBack = stubFastForwardMergeBackPerformer { _ in
      FastForwardMergeBackResult(
        baseBranchName: "main",
        headBranchName: "feature/window",
        branchHead: "def456",
        landedCommitCount: 1
      )
    }
    defer { restoreMergeBack() }

    let state = makeState()
    selectFeatureWorktree(in: state)
    state.selectedBranchTopology = BranchTopology(aheadCount: 1, behindCount: 0)

    state.beginMergeBackFlow()

    #expect(state.activeFinalizeAction == nil)
    #expect(state.isPresentingMergeBackOptions == false)
    #expect(state.mergeBackOptions.isEmpty)
    #expect(state.isPresentingAgentLaunchSheet == false)
    #expect(state.isMergeBackInProgress(for: "/tmp/repo/feature") == true)
    #expect(
      await waitUntil {
        state.isMergeBackCompleted(for: "/tmp/repo/feature")
      })
    #expect(state.isMergeBackInProgress(for: "/tmp/repo/feature") == false)
    #expect(
      state.launchWarningMessage == "Fast-forwarded main to feature/window (1 commit)."
    )
  }

  @Test("merge back falls back to an agent when local fast-forward is unavailable")
  @MainActor
  func mergeBackFallsBackToAgentWhenLocalFastForwardIsUnavailable() async {
    let restoreMergeBack = stubFastForwardMergeBackPerformer { _ in
      throw GitService.GitError.commandFailed("The linked worktree has uncommitted changes.")
    }
    defer { restoreMergeBack() }

    let state = makeState()
    selectFeatureWorktree(in: state)
    state.selectedBranchTopology = BranchTopology(aheadCount: 1, behindCount: 0)

    state.beginMergeBackFlow()

    #expect(state.isMergeBackInProgress(for: "/tmp/repo/feature") == true)
    #expect(
      await waitUntil {
        state.activeFinalizeAction == .fastForwardToBase
          && state.isPresentingAgentLaunchSheet
      })
    #expect(state.isMergeBackInProgress(for: "/tmp/repo/feature") == false)
    #expect(state.isMergeBackCompleted(for: "/tmp/repo/feature") == false)
  }

  @Test("merge back with no ahead commits starts a commit-first flow")
  @MainActor
  func mergeBackWithNoAheadCommitsStartsCommitFirstFlow() throws {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.selectedBranchTopology = BranchTopology(aheadCount: 0, behindCount: 0)

    #expect(state.canMergeBackSelectedWorktree == true)

    state.beginMergeBackFlow()

    #expect(state.activeFinalizeAction == .fastForwardToBase)
    #expect(state.isPresentingMergeBackOptions == false)
    #expect(state.mergeBackOptions.isEmpty)
    #expect(state.isPresentingAgentLaunchSheet == true)

    let prompt = try state.finalizePrompt(for: .fastForwardToBase)
    #expect(prompt.contains("No commits ahead yet:"))
    #expect(prompt.contains("create one clear commit on feature/window before landing it"))
  }

  @Test("merge back rebases a single diverged commit without showing strategy choices")
  @MainActor
  func mergeBackRebasesSingleDivergedCommitWithoutShowingStrategyChoices() {
    let state = makeState()
    selectFeatureWorktree(in: state)
    state.selectedBranchTopology = BranchTopology(aheadCount: 1, behindCount: 2)

    state.beginMergeBackFlow()

    #expect(state.activeFinalizeAction == .rebaseAndMergeToBase)
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

  @Test("agent launch options keep terminal persistence experimental")
  @MainActor
  func agentLaunchOptionsKeepTerminalPersistenceExperimental() {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(false)
    defer { restoreExperiment() }

    let defaultRequest = WorkspaceAgentLaunchOptions(
      source: .savedProfile(AgentFamilyID.codex.defaultProfile, yoloMode: true),
      sandboxEnabled: true
    )
    .buildRequest()

    #expect(defaultRequest.keepRunningWhileThinking == false)

    UserDefaults.standard.set(
      true,
      forKey: AgentTerminalPersistenceExperimentSettings.enabledStorageKey
    )
    let enabledRequest = WorkspaceAgentLaunchOptions(
      source: .savedProfile(AgentFamilyID.codex.defaultProfile, yoloMode: true),
      sandboxEnabled: true
    )
    .buildRequest()

    #expect(enabledRequest.keepRunningWhileThinking == TerminalSessionBackends.isAvailable())
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

  @Test("typed finalize failure responses surface an error and clear pending state")
  @MainActor
  func typedFinalizeFailureResponsesSurfaceAnError() async throws {
    let state = makeState()
    selectFeatureWorktree(in: state)

    let prompt = try state.prepareFinalizePrompt(
      for: .openPullRequest,
      sourceTabID: UUID()
    )
    let pending = try #require(
      state.pendingFinalizeRequest(for: .openPullRequest, worktreePath: "/tmp/repo/feature")
    )

    #expect(prompt.contains(pending.responseFilePath))

    let response = WorkspaceAgentControlResponse.finalize(
      requestID: pending.request.id,
      action: .openPullRequest,
      status: .failed,
      message: "GitHub authentication is not configured.",
      branchHead: nil,
      pullRequestURL: nil,
      followUp: nil
    )
    try write(agentControlResponse: response, to: pending.responseFilePath)

    #expect(
      await waitUntil {
        state.errorMessage == "GitHub authentication is not configured."
      })
    #expect(
      state.pendingFinalizeRequest(for: .openPullRequest, worktreePath: "/tmp/repo/feature") == nil)
  }

  @Test("successful merge back marks worktree done and clears agent input state")
  @MainActor
  func successfulMergeBackMarksWorktreeDoneAndClearsAgentInputState() async throws {
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

    let prompt = try state.prepareFinalizePrompt(
      for: .fastForwardToBase,
      sourceTabID: tab.id
    )
    let pending = try #require(
      state.pendingFinalizeRequest(for: .fastForwardToBase, worktreePath: "/tmp/repo/feature")
    )
    tab.hasAttention = true
    tab.agentActivityState = .waitingForHuman

    #expect(prompt.contains(pending.responseFilePath))
    #expect(state.isMergeBackInProgress(for: "/tmp/repo/feature") == true)

    let response = WorkspaceAgentControlResponse.finalize(
      requestID: pending.request.id,
      action: .fastForwardToBase,
      status: .success,
      message: "Fast-forwarded main.",
      branchHead: "abc123def456",
      pullRequestURL: nil,
      followUp: nil
    )
    try write(agentControlResponse: response, to: pending.responseFilePath)

    #expect(
      await waitUntil {
        state.isMergeBackCompleted(for: "/tmp/repo/feature")
      })
    #expect(state.isMergeBackInProgress(for: "/tmp/repo/feature") == false)
    #expect(
      state.pendingFinalizeRequest(for: .fastForwardToBase, worktreePath: "/tmp/repo/feature")
        == nil)
    #expect(tab.hasAttention == false)
    #expect(tab.agentActivityState == .idle)
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

  @Test("revealing a worktree selected tab clears attention after dwell")
  @MainActor
  func revealingWorktreeSelectedTabClearsAttentionAfterDwell() async throws {
    let previousDelay = WorkspaceState.terminalAttentionVisibleClearDelay
    WorkspaceState.terminalAttentionVisibleClearDelay = .milliseconds(40)
    defer {
      WorkspaceState.terminalAttentionVisibleClearDelay = previousDelay
    }

    let state = makeState()
    state.openShellTab()

    selectFeatureWorktree(in: state)
    let featureTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          sandboxEnabled: false
        ))
    )

    state.markTerminalNeedsAttention(featureTab.id)
    state.markAgentWaitingForHuman(featureTab.id)
    state.selectedWorktreePath = "/tmp/repo"

    #expect(featureTab.hasAttention == true)
    #expect(state.worktreeNeedsAttention(for: "/tmp/repo/feature") == true)

    selectFeatureWorktree(in: state)
    #expect(state.selectedTerminalTab?.id == featureTab.id)

    state.beginTerminalAttentionVisibilityDwell(for: featureTab.id)

    #expect(
      await waitUntil {
        featureTab.hasAttention == false && featureTab.agentActivityState == .idle
      })
    #expect(state.worktreeNeedsAttention(for: "/tmp/repo/feature") == false)
  }

  @Test("terminal attention dwell requires tab to stay selected")
  @MainActor
  func terminalAttentionDwellRequiresTabToStaySelected() async throws {
    let previousDelay = WorkspaceState.terminalAttentionVisibleClearDelay
    WorkspaceState.terminalAttentionVisibleClearDelay = .milliseconds(40)
    defer {
      WorkspaceState.terminalAttentionVisibleClearDelay = previousDelay
    }

    let state = makeState()
    state.openShellTab()
    let tab = try #require(state.selectedTerminalTab)

    state.markTerminalNeedsAttention(tab.id)
    state.beginTerminalAttentionVisibilityDwell(for: tab.id)
    selectFeatureWorktree(in: state)

    try await Task.sleep(for: .milliseconds(100))

    #expect(tab.hasAttention == true)
    #expect(state.worktreeNeedsAttention(for: "/tmp/repo") == true)
  }

  @Test("flashTerminalBell shows a transient bell indicator")
  @MainActor
  func flashTerminalBellShowsATransientBellIndicator() async throws {
    let previousDuration = WorkspaceState.terminalBellFlashDuration
    WorkspaceState.terminalBellFlashDuration = .milliseconds(50)
    defer { WorkspaceState.terminalBellFlashDuration = previousDuration }

    let state = makeState()
    state.openShellTab()
    let tab = try #require(state.selectedTerminalTab)

    #expect(tab.isShowingBellIndicator == false)

    state.flashTerminalBell(tab.id)

    #expect(tab.isShowingBellIndicator == true)

    try await Task.sleep(for: .milliseconds(120))

    #expect(tab.isShowingBellIndicator == false)
    #expect(tab.hasAttention == false)
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

  @Test("diff mode selector is forced to uncommitted for the base worktree")
  @MainActor
  func diffModeSelectorIsForcedToUncommittedForBaseWorktree() {
    let state = makeState()

    #expect(state.selectedDiffMode == .uncommitted)
    #expect(state.selectedWorktreeSupportsAllChanges == false)

    state.selectDiffMode(.allChanges)

    #expect(state.selectedDiffMode == .uncommitted)
    #expect(state.isLoadingSelectionDetails == false)
  }

  @Test("diff mode selector can switch feature worktrees to uncommitted")
  @MainActor
  func diffModeSelectorCanSwitchFeatureWorktreesToUncommitted() {
    let state = makeState()
    selectFeatureWorktree(in: state)

    #expect(state.selectedDiffMode == .allChanges)
    #expect(state.selectedWorktreeSupportsAllChanges == true)

    state.selectDiffMode(.uncommitted)

    #expect(state.selectedDiffMode == .uncommitted)
    #expect(state.selectedReviewTarget == nil)
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
    let restoredCodexTab = try #require(
      restoredState.selectedTerminalTabs.first { $0.id == codexTab.id })
    #expect(restoredCodexTab.shouldSuppressAttention())
    let restoredShellTab = try #require(
      restoredState.selectedTerminalTabs.first { $0.title == "Privileged Shell 1" })
    #expect(restoredShellTab.suppressAttentionUntil == nil)
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

  @Test("cold restorable agents stay lazy in sidebar status")
  @MainActor
  func coldRestorableAgentsStayLazyInSidebarStatus() {
    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 3),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            hasAttention: false,
            agentActivityState: .thinking
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [:]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)

    #expect(state.allTerminalTabs.isEmpty)
    #expect(state.selectedTerminalTabs.isEmpty)
    #expect(state.runningAgentCount == 0)
    #expect(state.activeAgentCount(for: "/tmp/repo/feature") == 0)
    #expect(state.agentActivitySummary(for: "/tmp/repo/feature") == .empty)
    #expect(!state.worktreeNeedsAttention(for: "/tmp/repo/feature"))
  }

  @Test("unscoped preserved agents do not contribute sidebar status")
  @MainActor
  func unscopedPreservedAgentsDoNotContributeSidebarStatus() {
    let preservedSession = TerminalSessionBackends.markPreservedForRestore(
      reference: TerminalSessionReference(backendID: "argon", sessionID: "unscoped-session")
    )
    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 4),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            keepsRunningAfterQuit: true,
            terminalSession: preservedSession,
            hasAttention: true,
            agentActivityState: .waitingForHuman
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [:]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)

    #expect(state.allTerminalTabs.isEmpty)
    #expect(state.runningAgentCount == 0)
    #expect(state.activeAgentCount(for: "/tmp/repo/feature") == 0)
    #expect(state.agentActivitySummary(for: "/tmp/repo/feature") == .empty)
    #expect(!state.worktreeNeedsAttention(for: "/tmp/repo/feature"))
  }

  @Test("running preserved agents restore in the background while other tabs stay lazy")
  @MainActor
  func runningPreservedAgentsRestoreInTheBackgroundWhileOtherTabsStayLazy() async {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    let liveTabID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    let lazyTabID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    let preservedSession = TerminalSessionBackends.markPreservedForRestore(
      reference: TerminalSessionReference(
        backendID: "argon",
        sessionID: "argon-background-running",
        context: [
          TerminalSessionReferenceContextKey.storageDirectory:
            "/tmp/argon-workspace-state-background-running"
        ]
      )
    )
    WorkspaceState.terminalSessionReconnectChecker = { session in
      session.sessionID == preservedSession.sessionID
    }
    WorkspaceState.terminalSessionRunningChecker = { session in
      session.sessionID == preservedSession.sessionID
    }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      restoreExperiment()
      WorkspaceState.terminalSessionReconnectChecker = { session in
        TerminalSessionBackends.canReconnect(reference: session)
      }
      WorkspaceState.terminalSessionRunningChecker = { session in
        TerminalSessionBackends.isRunning(reference: session)
      }
      WorkspaceState.commandStatusProvider = nil
    }

    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: liveTabID,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 5),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            keepsRunningAfterQuit: true,
            terminalSession: preservedSession,
            agentActivityState: .thinking
          ),
          PersistedWorkspaceTerminalTab(
            id: lazyTabID,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Gemini",
            commandDescription: "gemini",
            kind: .agent(profileName: "Gemini", icon: "sparkles"),
            agentFamilyID: .gemini,
            createdAt: Date(timeIntervalSince1970: 6),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"]
          ),
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": lazyTabID
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)

    #expect(state.selectedWorktreePath == "/tmp/repo")
    #expect(state.selectedTerminalTabs.isEmpty)
    #expect(state.activeAgentCount(for: "/tmp/repo/feature") == 1)
    #expect(
      state.agentActivitySummary(for: "/tmp/repo/feature")
        == WorktreeAgentActivitySummary(
          waitingForHumanCount: 0,
          thinkingCount: 1,
          runningAgentCount: 1
        )
    )

    #expect(
      await waitUntil {
        state.terminalTabsByWorktreePath["/tmp/repo/feature"]?.contains {
          $0.id == liveTabID
        } == true
      }
    )

    #expect(state.selectedTerminalTabs.isEmpty)
    #expect(state.terminalTabsByWorktreePath["/tmp/repo/feature"]?.map(\.id) == [liveTabID])
    #expect(
      state.selectedTerminalTabIDsByWorktreePath["/tmp/repo/feature"] == lazyTabID)
    #expect(state.activeAgentCount(for: "/tmp/repo/feature") == 1)

    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(
      await waitUntil {
        state.selectedTerminalTabs.contains { $0.id == lazyTabID }
      }
    )
    #expect(Set(state.selectedTerminalTabs.map(\.id)) == Set([liveTabID, lazyTabID]))
    #expect(state.selectedTerminalTab?.id == lazyTabID)
  }

  @Test("running unpreserved terminal sessions restore in the background")
  @MainActor
  func runningUnpreservedTerminalSessionsRestoreInTheBackground() async {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    let liveTabID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    let runningSession = TerminalSessionReference(
      backendID: "argon",
      sessionID: "argon-background-idle",
      context: [
        TerminalSessionReferenceContextKey.storageDirectory:
          "/tmp/argon-workspace-state-background-idle"
      ]
    )
    WorkspaceState.terminalSessionReconnectChecker = { session in
      session.sessionID == runningSession.sessionID
    }
    WorkspaceState.terminalSessionRunningChecker = { session in
      session.sessionID == runningSession.sessionID
    }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      restoreExperiment()
      WorkspaceState.terminalSessionReconnectChecker = { session in
        TerminalSessionBackends.canReconnect(reference: session)
      }
      WorkspaceState.terminalSessionRunningChecker = { session in
        TerminalSessionBackends.isRunning(reference: session)
      }
      WorkspaceState.commandStatusProvider = nil
    }

    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: liveTabID,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 7),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            keepsRunningAfterQuit: true,
            terminalSession: runningSession,
            agentActivityState: .idle
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": liveTabID
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)

    #expect(state.selectedTerminalTabs.isEmpty)
    #expect(state.activeAgentCount(for: "/tmp/repo/feature") == 1)
    #expect(
      state.agentActivitySummary(for: "/tmp/repo/feature")
        == WorktreeAgentActivitySummary(
          waitingForHumanCount: 0,
          thinkingCount: 0,
          runningAgentCount: 1
        )
    )

    #expect(
      await waitUntil {
        state.terminalTabsByWorktreePath["/tmp/repo/feature"]?.contains {
          $0.id == liveTabID && $0.terminalSession == runningSession
        } == true
      }
    )
    #expect(state.selectedTerminalTabs.isEmpty)
    #expect(state.activeAgentCount(for: "/tmp/repo/feature") == 1)
  }

  @Test("late snapshots merge running background agents into sidebar status")
  @MainActor
  func lateSnapshotsMergeRunningBackgroundAgentsIntoSidebarStatus() async {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    let liveTabID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    let coldTabID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    let runningSession = TerminalSessionReference(
      backendID: "argon",
      sessionID: "argon-late-background",
      context: [
        TerminalSessionReferenceContextKey.storageDirectory:
          "/tmp/argon-workspace-state-late-background"
      ]
    )
    WorkspaceState.terminalSessionReconnectChecker = { session in
      session.sessionID == runningSession.sessionID
    }
    WorkspaceState.terminalSessionRunningChecker = { session in
      session.sessionID == runningSession.sessionID
    }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    WorkspaceState.tabRestoreTestDelay = .milliseconds(150)
    defer {
      restoreExperiment()
      WorkspaceState.terminalSessionReconnectChecker = { session in
        TerminalSessionBackends.canReconnect(reference: session)
      }
      WorkspaceState.terminalSessionRunningChecker = { session in
        TerminalSessionBackends.isRunning(reference: session)
      }
      WorkspaceState.commandStatusProvider = nil
      WorkspaceState.tabRestoreTestDelay = nil
    }

    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: liveTabID,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 8),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            keepsRunningAfterQuit: true,
            terminalSession: runningSession,
            hasAttention: true,
            agentActivityState: .waitingForHuman
          ),
          PersistedWorkspaceTerminalTab(
            id: coldTabID,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Gemini",
            commandDescription: "gemini",
            kind: .agent(profileName: "Gemini", icon: "sparkles"),
            agentFamilyID: .gemini,
            createdAt: Date(timeIntervalSince1970: 9),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"]
          ),
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": coldTabID
      ]
    )

    let state = makeState()

    #expect(!state.canSeedFromPersistedWindowSnapshot)

    state.mergePersistedRunningAgentTabs(from: snapshot)

    #expect(state.selectedWorktreePath == "/tmp/repo")
    #expect(state.selectedTerminalTabs.isEmpty)
    #expect(state.activeAgentCount(for: "/tmp/repo/feature") == 1)
    #expect(state.worktreeNeedsAttention(for: "/tmp/repo/feature"))
    #expect(
      state.agentActivitySummary(for: "/tmp/repo/feature")
        == WorktreeAgentActivitySummary(
          waitingForHumanCount: 1,
          thinkingCount: 0,
          runningAgentCount: 1
        )
    )
    #expect(state.terminalTabsByWorktreePath["/tmp/repo/feature"] == nil)

    #expect(
      await waitUntil {
        state.terminalTabsByWorktreePath["/tmp/repo/feature"]?.map(\.id) == [liveTabID]
      }
    )
    #expect(state.selectedWorktreePath == "/tmp/repo")
    #expect(state.selectedTerminalTabs.isEmpty)
    #expect(state.activeAgentCount(for: "/tmp/repo/feature") == 1)
    #expect(state.worktreeNeedsAttention(for: "/tmp/repo/feature"))
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

  @Test("unchanged worktree metadata does not refresh details")
  func unchangedWorktreeMetadataDoesNotRefreshDetails() {
    let currentWorktrees = [
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      )
    ]
    let discoveredWorktrees = [
      DiscoveredWorktree(
        path: "/private/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      )
    ]

    #expect(
      WorkspaceState.shouldRefreshWorktreeDetails(
        currentWorktrees: currentWorktrees,
        discoveredWorktrees: discoveredWorktrees
      ) == false
    )
  }

  @Test("changed worktree metadata refreshes details")
  func changedWorktreeMetadataRefreshesDetails() {
    let currentWorktrees = [
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      )
    ]
    let discoveredWorktrees = [
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "def456",
        isBaseWorktree: true,
        isDetached: false
      )
    ]

    #expect(
      WorkspaceState.shouldRefreshWorktreeDetails(
        currentWorktrees: currentWorktrees,
        discoveredWorktrees: discoveredWorktrees
      )
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

  @Test("inventory updates select the next worktree when the selected worktree disappears")
  @MainActor
  func inventoryUpdatesSelectTheNextWorktreeWhenTheSelectedWorktreeDisappears() {
    let state = makeState()
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
      DiscoveredWorktree(
        path: "/tmp/repo/review",
        branchName: "review/comments",
        headSHA: "ghi789",
        isBaseWorktree: false,
        isDetached: false
      ),
    ]
    state.selectedWorktreePath = "/tmp/repo/feature"

    state.applyDiscoveredWorktreeInventory([
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
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

    #expect(state.selectedWorktreePath == "/tmp/repo/review")
    #expect(state.worktrees.map(\.path) == ["/tmp/repo", "/tmp/repo/review"])
  }

  @Test("inventory updates select the previous worktree when the selected worktree was last")
  @MainActor
  func inventoryUpdatesSelectThePreviousWorktreeWhenTheSelectedWorktreeWasLast() {
    let state = makeState()
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
      DiscoveredWorktree(
        path: "/tmp/repo/review",
        branchName: "review/comments",
        headSHA: "ghi789",
        isBaseWorktree: false,
        isDetached: false
      ),
    ]
    state.selectedWorktreePath = "/tmp/repo/review"

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
    ])

    #expect(state.selectedWorktreePath == "/tmp/repo/feature")
    #expect(state.worktrees.map(\.path) == ["/tmp/repo", "/tmp/repo/feature"])
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
      hasInitializedSubmodules: false,
      submodulesWithUnpushedCommits: [],
      canDeleteBranch: true,
      branchComparisonBaseRef: "main",
      branchHasUniqueCommits: false,
      branchHasUnpushedCommits: false
    )

    #expect(request.shouldSkipConfirmation == true)
    #expect(request.defaultDeletesBranch == true)
  }

  @Test("unpushed branch commits require worktree removal confirmation")
  func unpushedBranchCommitsRequireWorktreeRemovalConfirmation() {
    let request = WorktreeRemovalRequest(
      worktreePath: "/tmp/repo/feature",
      displayName: "feature/unpushed",
      branchName: "feature/unpushed",
      hasUncommittedChanges: false,
      hasInitializedSubmodules: false,
      submodulesWithUnpushedCommits: [],
      canDeleteBranch: true,
      branchComparisonBaseRef: "main",
      branchHasUniqueCommits: false,
      branchHasUnpushedCommits: true
    )

    #expect(request.shouldSkipConfirmation == false)
  }

  @Test("unpushed submodule commits require worktree removal confirmation")
  func unpushedSubmoduleCommitsRequireWorktreeRemovalConfirmation() {
    let request = WorktreeRemovalRequest(
      worktreePath: "/tmp/repo/feature",
      displayName: "feature/submodule",
      branchName: "feature/submodule",
      hasUncommittedChanges: false,
      hasInitializedSubmodules: true,
      submodulesWithUnpushedCommits: [
        SubmoduleUnpushedCommits(path: "vendor/sub", commitCount: 1)
      ],
      canDeleteBranch: true,
      branchComparisonBaseRef: "main",
      branchHasUniqueCommits: false,
      branchHasUnpushedCommits: false
    )

    #expect(request.shouldSkipConfirmation == false)
  }

  @Test("worktree removal failures are prepared for an alert dialog")
  @MainActor
  func worktreeRemovalFailuresArePreparedForAnAlertDialog() throws {
    let state = makeState()

    state.presentWorktreeRemovalError(
      GitService.GitError.commandFailed("fatal: '/tmp/repo/feature' is locked"),
      worktreeName: "feature/window"
    )

    let dialog = try #require(state.worktreeRemovalErrorDialog)
    #expect(dialog.title == "Couldn't Remove Worktree")
    #expect(dialog.message.contains("Argon couldn't remove feature/window."))
    #expect(dialog.message.contains("fatal: '/tmp/repo/feature' is locked"))

    state.dismissWorktreeRemovalError()
    #expect(state.worktreeRemovalErrorDialog == nil)
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
    state.reviewTargetsByWorktreePath["/tmp/repo"] = ResolvedTarget(
      mode: .branch,
      baseRef: "origin/main",
      headRef: "feature/workspace",
      mergeBaseSha: "abc123"
    )
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
    AgentHarnesses.resumeSessionRecordsProvider = {
      [
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "11111111-1111-1111-1111-111111111111",
          cwd: "/tmp/repo/feature",
          startedAt: Date(timeIntervalSince1970: 11)
        ),
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "22222222-2222-2222-2222-222222222222",
          cwd: "/tmp/repo/feature",
          startedAt: Date(timeIntervalSince1970: 21)
        ),
      ]
    }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      WorkspaceState.commandStatusProvider = nil
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }

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
    AgentHarnesses.resumeSessionRecordsProvider = { [] }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      WorkspaceState.commandStatusProvider = nil
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }

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

  @Test("restorable agent sessions include supported families for selected worktree")
  @MainActor
  func restorableAgentSessionsIncludeSupportedFamiliesForSelectedWorktree() {
    AgentHarnesses.resumeSessionRecordsProvider = {
      [
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "codex-current",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 30)
        ),
        AgentResumeSessionRecord(
          familyID: .claudeCode,
          sessionID: "claude-current",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 20)
        ),
        AgentResumeSessionRecord(
          familyID: .gemini,
          sessionID: "gemini-current",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 10)
        ),
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "codex-other",
          cwd: "/tmp/other",
          startedAt: Date(timeIntervalSince1970: 40)
        ),
      ]
    }
    defer {
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }

    let state = makeState()
    let sessions = state.restorableAgentSessions(savedProfiles: SavedAgentProfiles.builtinDefaults)

    #expect(sessions.map(\.sessionID) == ["codex-current", "claude-current", "gemini-current"])
    #expect(sessions.map(\.familyID) == [.codex, .claudeCode, .gemini])
    #expect(
      sessions.first(where: { $0.familyID == .claudeCode })?.resumeArgumentTemplate
        == "--resume {{session_id}}")
    #expect(
      sessions.first(where: { $0.familyID == .gemini })?.resumeArgumentTemplate
        == "--resume {{session_id}}")
  }

  @Test("restoring an agent session launches sandboxed")
  @MainActor
  func restoringAgentSessionLaunchesSandboxed() throws {
    AgentHarnesses.resumeSessionRecordsProvider = {
      [
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "11111111-1111-1111-1111-111111111111",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 30)
        )
      ]
    }
    defer {
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }

    let state = makeState()
    let session = try #require(
      state.restorableAgentSessions(savedProfiles: SavedAgentProfiles.builtinDefaults).first)
    let tab = try #require(state.restoreAgentSession(session))

    #expect(tab.isSandboxed == true)
    #expect(tab.commandDescription == "codex")
    #expect(tab.resumeSessionID == "11111111-1111-1111-1111-111111111111")
    #expect(
      tab.resumeCommandDescription == "codex resume '11111111-1111-1111-1111-111111111111'")
    #expect(
      state.restorableAgentSessions(savedProfiles: SavedAgentProfiles.builtinDefaults).isEmpty)
  }

  @Test("restorable sessions without profile metadata use the builtin profile")
  @MainActor
  func restorableSessionsWithoutProfileMetadataUseTheBuiltinProfile() throws {
    let restoreMetadataStore = isolateAgentSessionRestoreMetadataStoreForTest()
    defer { restoreMetadataStore() }

    AgentHarnesses.resumeSessionRecordsProvider = {
      [
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "11111111-1111-1111-1111-111111111111",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 30)
        )
      ]
    }
    defer {
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }

    let codexCopy = SavedAgentProfile(
      id: "codex-copy",
      kind: .harnessProfile(.codex),
      name: "Codex Copy",
      command: "codex",
      icon: "codex",
      parameterValues: ["model": "gpt-5.5", "reasoning": "high"],
      yoloFlag: "--yolo",
      resumeArgumentTemplate: "resume {{session_id}}"
    )

    let state = makeState()
    let session = try #require(
      state.restorableAgentSessions(
        savedProfiles: SavedAgentProfiles.builtinDefaults + [codexCopy]
      ).first)

    #expect(session.profileID == "codex")
    #expect(session.profileName == "Codex")
    #expect(session.command == "codex")
  }

  @Test("restorable sessions use exact profile metadata when available")
  @MainActor
  func restorableSessionsUseExactProfileMetadataWhenAvailable() throws {
    let restoreMetadataStore = isolateAgentSessionRestoreMetadataStoreForTest()
    defer { restoreMetadataStore() }

    AgentHarnesses.resumeSessionRecordsProvider = {
      [
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "22222222-2222-2222-2222-222222222222",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 30)
        )
      ]
    }
    defer {
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }

    let codexCopy = SavedAgentProfile(
      id: "codex-copy",
      kind: .harnessProfile(.codex),
      name: "Codex Copy",
      command: "codex",
      icon: "codex",
      parameterValues: ["model": "gpt-5.5", "reasoning": "high"],
      yoloFlag: "--yolo",
      resumeArgumentTemplate: "resume {{session_id}}"
    )
    AgentSessionRestoreMetadataStore.record(
      AgentSessionRestoreMetadata(
        familyID: .codex,
        profileID: "codex-copy",
        sessionID: "22222222-2222-2222-2222-222222222222",
        cwd: "/tmp/repo",
        yoloMode: false,
        sandboxEnabled: true,
        updatedAt: Date(timeIntervalSince1970: 40)
      )
    )

    let state = makeState()
    let session = try #require(
      state.restorableAgentSessions(
        savedProfiles: SavedAgentProfiles.builtinDefaults + [codexCopy]
      ).first)

    #expect(session.profileID == "codex-copy")
    #expect(session.profileName == "Codex Copy")
    #expect(
      session.command == "codex -m 'gpt-5.5' -c 'model_reasoning_effort=\"high\"'")
  }

  @Test("restorable sessions fall back to default when exact profile is missing")
  @MainActor
  func restorableSessionsFallBackToDefaultWhenExactProfileIsMissing() throws {
    let restoreMetadataStore = isolateAgentSessionRestoreMetadataStoreForTest()
    defer { restoreMetadataStore() }

    AgentHarnesses.resumeSessionRecordsProvider = {
      [
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "22222222-2222-2222-2222-222222222222",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 30)
        )
      ]
    }
    defer {
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }

    AgentSessionRestoreMetadataStore.record(
      AgentSessionRestoreMetadata(
        familyID: .codex,
        profileID: "deleted-codex-profile",
        sessionID: "22222222-2222-2222-2222-222222222222",
        cwd: "/tmp/repo",
        yoloMode: false,
        sandboxEnabled: true,
        updatedAt: Date(timeIntervalSince1970: 40)
      )
    )

    let state = makeState()
    let session = try #require(
      state.restorableAgentSessions(savedProfiles: SavedAgentProfiles.builtinDefaults).first)

    #expect(session.profileID == "codex")
    #expect(session.profileName == "Codex")
    #expect(session.command == "codex")
  }

  @Test("stopped agent tabs do not hide their resumable session")
  @MainActor
  func stoppedAgentTabsDoNotHideTheirResumableSession() throws {
    let restoreMetadataStore = isolateAgentSessionRestoreMetadataStoreForTest()
    defer { restoreMetadataStore() }

    AgentHarnesses.resumeSessionRecordsProvider = {
      [
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "11111111-1111-1111-1111-111111111111",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 30)
        )
      ]
    }
    defer {
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }

    let state = makeState()
    let stoppedTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          resumeArgumentTemplate: "resume {{session_id}}",
          resumeSessionID: "11111111-1111-1111-1111-111111111111"
        ))
    )
    stoppedTab.isRunning = false

    let session = try #require(
      state.restorableAgentSessions(savedProfiles: SavedAgentProfiles.builtinDefaults).first)

    #expect(session.sessionID == "11111111-1111-1111-1111-111111111111")
    #expect(session.openStoppedTabID == stoppedTab.id)
  }

  @Test("restoring a stopped tab session closes the old tab")
  @MainActor
  func restoringStoppedTabSessionClosesTheOldTab() throws {
    let restoreMetadataStore = isolateAgentSessionRestoreMetadataStoreForTest()
    defer { restoreMetadataStore() }

    AgentHarnesses.resumeSessionRecordsProvider = {
      [
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "11111111-1111-1111-1111-111111111111",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 30)
        )
      ]
    }
    defer {
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }

    let state = makeState()
    let stoppedTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          resumeArgumentTemplate: "resume {{session_id}}",
          resumeSessionID: "11111111-1111-1111-1111-111111111111"
        ))
    )
    stoppedTab.isRunning = false

    let session = try #require(
      state.restorableAgentSessions(savedProfiles: SavedAgentProfiles.builtinDefaults).first)
    let restoredTab = try #require(state.restoreAgentSession(session))

    #expect(!state.allTerminalTabs.contains { $0.id == stoppedTab.id })
    #expect(state.allTerminalTabs.contains { $0.id == restoredTab.id })
    #expect(restoredTab.id != stoppedTab.id)
    #expect(restoredTab.resumeSessionID == "11111111-1111-1111-1111-111111111111")
    #expect(
      restoredTab.resumeCommandDescription == "codex resume '11111111-1111-1111-1111-111111111111'")
  }

  @Test("restoring an agent session uses persisted launch modes")
  @MainActor
  func restoringAgentSessionUsesPersistedLaunchModes() throws {
    let restoreMetadataStore = isolateAgentSessionRestoreMetadataStoreForTest()
    defer { restoreMetadataStore() }

    AgentHarnesses.resumeSessionRecordsProvider = {
      [
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: "22222222-2222-2222-2222-222222222222",
          cwd: "/tmp/repo",
          startedAt: Date(timeIntervalSince1970: 30)
        )
      ]
    }
    defer {
      AgentHarnesses.resumeSessionRecordsProvider = nil
    }
    AgentSessionRestoreMetadataStore.record(
      AgentSessionRestoreMetadata(
        familyID: .codex,
        sessionID: "22222222-2222-2222-2222-222222222222",
        cwd: "/tmp/repo",
        yoloMode: true,
        sandboxEnabled: false,
        updatedAt: Date(timeIntervalSince1970: 40)
      )
    )

    let state = makeState()
    let session = try #require(
      state.restorableAgentSessions(savedProfiles: SavedAgentProfiles.builtinDefaults).first)
    let tab = try #require(state.restoreAgentSession(session))

    #expect(session.yoloMode == true)
    #expect(session.sandboxEnabled == false)
    #expect(tab.yoloMode == true)
    #expect(tab.isSandboxed == false)
    #expect(tab.commandDescription == "codex --yolo")
    #expect(tab.baseCommandDescription == "codex")
    #expect(
      tab.resumeCommandDescription == "codex --yolo resume '22222222-2222-2222-2222-222222222222'")
  }

  @Test("agent session restore metadata stores only durable launch modes")
  @MainActor
  func agentSessionRestoreMetadataStoresOnlyDurableLaunchModes() throws {
    let restoreMetadataStore = isolateAgentSessionRestoreMetadataStoreForTest()
    defer { restoreMetadataStore() }

    AgentSessionRestoreMetadataStore.record(
      AgentSessionRestoreMetadata(
        familyID: .codex,
        sessionID: "22222222-2222-2222-2222-222222222222",
        cwd: "/tmp/repo",
        yoloMode: true,
        sandboxEnabled: false,
        updatedAt: Date(timeIntervalSince1970: 40)
      )
    )

    let data = try #require(
      AgentSessionRestoreMetadataStore.userDefaults.data(
        forKey: AgentSessionRestoreMetadataStore.storageKey
      )
    )
    let json = String(decoding: data, as: UTF8.self)

    #expect(json.contains("\"yoloMode\""))
    #expect(json.contains("\"sandboxEnabled\""))
    #expect(!json.contains("\"profileName\""))
    #expect(!json.contains("\"command\""))
    #expect(!json.contains("\"icon\""))
    #expect(!json.contains("\"resumeArgumentTemplate\""))
    #expect(!json.contains("\"yoloFlag\""))
  }

  @Test("relaunching an agent tab updates yolo and sandbox modes")
  @MainActor
  func relaunchingAgentTabUpdatesYoloAndSandboxModes() throws {
    let restoreMetadataStore = isolateAgentSessionRestoreMetadataStoreForTest()
    defer { restoreMetadataStore() }

    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchOptions(
          source: .savedProfile(AgentFamilyID.codex.defaultProfile, yoloMode: false),
          sandboxEnabled: true
        )
        .buildRequest()
      )
    )
    tab.resumeSessionID = "33333333-3333-3333-3333-333333333333"

    let relaunched = try #require(
      state.relaunchAgentTab(tab.id, sandboxEnabled: false, yoloMode: true))

    #expect(!state.allTerminalTabs.contains { $0.id == tab.id })
    #expect(state.selectedTerminalTab?.id == relaunched.id)
    #expect(relaunched.isSandboxed == false)
    #expect(relaunched.yoloMode == true)
    #expect(relaunched.commandDescription == "codex --yolo")
    #expect(relaunched.baseCommandDescription == "codex")
    #expect(
      relaunched.resumeCommandDescription
        == "codex --yolo resume '33333333-3333-3333-3333-333333333333'")
  }

  @Test("relaunching an agent tab can change profile")
  @MainActor
  func relaunchingAgentTabCanChangeProfile() throws {
    let restoreMetadataStore = isolateAgentSessionRestoreMetadataStoreForTest()
    defer { restoreMetadataStore() }

    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchOptions(
          source: .savedProfile(AgentFamilyID.codex.defaultProfile, yoloMode: false),
          sandboxEnabled: true
        )
        .buildRequest()
      )
    )
    tab.resumeSessionID = "33333333-3333-3333-3333-333333333333"

    let codexCopy = SavedAgentProfile(
      id: "codex-copy",
      kind: .harnessProfile(.codex),
      name: "Codex Copy",
      command: "codex",
      icon: "codex",
      parameterValues: ["model": "gpt-5.5", "reasoning": "high"],
      yoloFlag: "--yolo",
      resumeArgumentTemplate: "resume {{session_id}}"
    )
    let relaunched = try #require(state.relaunchAgentTab(tab.id, profile: codexCopy))
    let metadata = try #require(
      AgentSessionRestoreMetadataStore.metadata(
        familyID: .codex,
        sessionID: "33333333-3333-3333-3333-333333333333",
        cwd: "/tmp/repo"
      )
    )

    #expect(relaunched.profileID == "codex-copy")
    #expect(relaunched.title == "Codex Copy")
    #expect(
      relaunched.commandDescription == "codex -m 'gpt-5.5' -c 'model_reasoning_effort=\"high\"'")
    #expect(
      relaunched.baseCommandDescription
        == "codex -m 'gpt-5.5' -c 'model_reasoning_effort=\"high\"'")
    #expect(metadata.profileID == "codex-copy")
  }

  @Test("lazy restore reconnects persistent terminal session when requested")
  @MainActor
  func lazyRestoreReconnectsPersistentTerminalSessionWhenRequested() async {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let session = TerminalSessionReference(backendID: "test", sessionID: "restored-session")
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionReferenceProvider = { _, _ in
      session
    }
    WorkspaceState.terminalSessionLaunchBuilder = Self.testTerminalSessionLaunchBuilder
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      WorkspaceState.terminalSessionReferenceProvider = { tabID, workspacePath in
        TerminalSessionBackends.reference(for: tabID, workspacePath: workspacePath)
      }
      WorkspaceState.terminalSessionLaunchBuilder = Self.defaultTerminalSessionLaunchBuilder
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
      WorkspaceState.commandStatusProvider = nil
    }

    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 40),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            resumeArgumentTemplate: "resume {{session_id}}",
            keepsRunningAfterQuit: true,
            resumeSessionID: "019de52a-af6e-7620-9d04-9c8ccd6158b7",
            resumeCommandDescription:
              "codex --yolo resume '019de52a-af6e-7620-9d04-9c8ccd6158b7'"
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)

    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(await waitUntil { state.selectedTerminalTabs.count == 1 })

    let tab = state.selectedTerminalTabs.first
    #expect(stoppedSessions.sessions == [session])
    #expect(tab?.terminalSession == session)
    #expect(tab?.keepsRunningAfterQuit == true)
    #expect(tab?.launch.processSpec.args.last?.contains("restored-session") == true)
    #expect(tab?.launch.processSpec.args.last?.contains("codex --yolo resume") == true)
  }

  @Test("lazy restore replaces legacy screen terminal sessions")
  @MainActor
  func lazyRestoreReplacesLegacyScreenTerminalSessions() async {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let legacySession = TerminalSessionReference(backendID: "screen", sessionID: "legacy-session")
    let replacementSession = TerminalSessionReference(
      backendID: "test",
      sessionID: "replacement-session"
    )
    WorkspaceState.terminalSessionReferenceProvider = { _, _ in
      replacementSession
    }
    WorkspaceState.terminalSessionLaunchBuilder = Self.testTerminalSessionLaunchBuilder
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      WorkspaceState.terminalSessionReferenceProvider = { tabID, workspacePath in
        TerminalSessionBackends.reference(for: tabID, workspacePath: workspacePath)
      }
      WorkspaceState.terminalSessionLaunchBuilder = Self.defaultTerminalSessionLaunchBuilder
      WorkspaceState.commandStatusProvider = nil
    }

    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 50),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            resumeArgumentTemplate: "resume {{session_id}}",
            keepsRunningAfterQuit: true,
            terminalSession: legacySession,
            resumeSessionID: "019de52a-af6e-7620-9d04-9c8ccd6158b7",
            resumeCommandDescription:
              "codex --yolo resume '019de52a-af6e-7620-9d04-9c8ccd6158b7'"
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)
    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(await waitUntil { state.selectedTerminalTabs.count == 1 })

    let tab = state.selectedTerminalTabs.first
    #expect(tab?.terminalSession == replacementSession)
    #expect(tab?.launch.processSpec.args.last?.contains("replacement-session") == true)
  }

  @Test("lazy restore upgrades legacy persistent terminal refs to keep running")
  @MainActor
  func lazyRestoreUpgradesLegacyPersistentTerminalRefsToKeepRunning() async throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let legacySession = TerminalSessionReference(backendID: "screen", sessionID: "legacy-session")
    let replacementSession = TerminalSessionReference(
      backendID: "test",
      sessionID: "replacement-session"
    )
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionReferenceProvider = { _, _ in
      replacementSession
    }
    WorkspaceState.terminalSessionLaunchBuilder = Self.testTerminalSessionLaunchBuilder
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    WorkspaceState.terminalSessionRunningChecker = { candidate in
      candidate == replacementSession
    }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      WorkspaceState.terminalSessionReferenceProvider = { tabID, workspacePath in
        TerminalSessionBackends.reference(for: tabID, workspacePath: workspacePath)
      }
      WorkspaceState.terminalSessionLaunchBuilder = Self.defaultTerminalSessionLaunchBuilder
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
      WorkspaceState.terminalSessionRunningChecker = { session in
        TerminalSessionBackends.isRunning(reference: session)
      }
      WorkspaceState.commandStatusProvider = nil
    }

    let tabID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: tabID,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 55),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            resumeArgumentTemplate: "resume {{session_id}}",
            keepsRunningAfterQuit: false,
            terminalSession: legacySession,
            resumeSessionID: "019de52a-af6e-7620-9d04-9c8ccd6158b7",
            resumeCommandDescription:
              "codex --yolo resume '019de52a-af6e-7620-9d04-9c8ccd6158b7'"
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": tabID
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)
    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(await waitUntil { state.selectedTerminalTabs.count == 1 })

    let tab = try #require(state.selectedTerminalTabs.first)
    let originalViewIdentity = tab.terminalViewIdentity
    #expect(stoppedSessions.sessions == [legacySession])
    #expect(tab.terminalSession == replacementSession)
    #expect(tab.keepsRunningAfterQuit == true)

    state.handleTerminalExit(tab.id, exitBehavior: .keepOpen)

    #expect(tab.terminalSession == replacementSession)
    #expect(tab.isRunning)
    #expect(tab.terminalViewIdentity != originalViewIdentity)
    #expect(tab.terminalSessionReconnectCount == 1)
    #expect(stoppedSessions.sessions == [legacySession])
  }

  @Test("lazy restore replaces unmarked persistent terminal sessions")
  @MainActor
  func lazyRestoreReplacesUnmarkedPersistentTerminalSessions() async {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let staleSession = TerminalSessionReference(backendID: "argon", sessionID: "stale-session")
    let replacementSession = TerminalSessionReference(
      backendID: "test",
      sessionID: "replacement-session"
    )
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionReferenceProvider = { _, _ in
      replacementSession
    }
    WorkspaceState.terminalSessionLaunchBuilder = Self.testTerminalSessionLaunchBuilder
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      WorkspaceState.terminalSessionReferenceProvider = { tabID, workspacePath in
        TerminalSessionBackends.reference(for: tabID, workspacePath: workspacePath)
      }
      WorkspaceState.terminalSessionLaunchBuilder = Self.defaultTerminalSessionLaunchBuilder
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
      WorkspaceState.commandStatusProvider = nil
    }

    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 60),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            resumeArgumentTemplate: "resume {{session_id}}",
            keepsRunningAfterQuit: true,
            terminalSession: staleSession,
            resumeSessionID: "019de52a-af6e-7620-9d04-9c8ccd6158b7",
            resumeCommandDescription:
              "codex --yolo resume '019de52a-af6e-7620-9d04-9c8ccd6158b7'"
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)
    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(await waitUntil { state.selectedTerminalTabs.count == 1 })

    let tab = state.selectedTerminalTabs.first
    #expect(stoppedSessions.sessions == [staleSession])
    #expect(tab?.terminalSession == replacementSession)
    #expect(tab?.launch.processSpec.args.last?.contains("replacement-session") == true)
    #expect(tab?.launch.processSpec.args.last?.contains("codex --yolo resume") == true)
  }

  @Test("lazy restore disables terminal session wrappers when experiment is off")
  @MainActor
  func lazyRestoreDisablesTerminalSessionWrappersWhenExperimentIsOff() async {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(false)
    defer { restoreExperiment() }

    let persistedSession = TerminalSessionReference(
      backendID: "argon",
      sessionID: "persisted-session"
    )
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
      WorkspaceState.commandStatusProvider = nil
    }

    let snapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/feature"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo/feature": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!,
            worktreePath: "/tmp/repo/feature",
            worktreeLabel: "feature/window",
            title: "Codex",
            commandDescription: "codex --yolo",
            kind: .agent(profileName: "Codex", icon: "codex"),
            agentFamilyID: .codex,
            createdAt: Date(timeIntervalSince1970: 70),
            isSandboxed: true,
            writableRoots: ["/tmp/repo/feature"],
            resumeArgumentTemplate: "resume {{session_id}}",
            keepsRunningAfterQuit: true,
            terminalSession: persistedSession,
            resumeSessionID: "019de52a-af6e-7620-9d04-9c8ccd6158b7",
            resumeCommandDescription:
              "codex --yolo resume '019de52a-af6e-7620-9d04-9c8ccd6158b7'"
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo/feature": UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!
      ]
    )

    let state = makeState()
    state.applyPersistedWindowSnapshot(snapshot)
    state.prepareSelectionLoading(for: "/tmp/repo/feature")
    #expect(await waitUntil { state.selectedTerminalTabs.count == 1 })

    let tab = state.selectedTerminalTabs.first
    #expect(stoppedSessions.sessions == [persistedSession])
    #expect(tab?.terminalSession == nil)
    #expect(tab?.launch.processSpec.args.last?.contains("attach persisted-session:") == false)
    #expect(tab?.launch.processSpec.args.last?.contains("codex --yolo resume") == true)
  }

  @Test("quit summary warns for thinking agent without persistence")
  @MainActor
  func quitSummaryWarnsForThinkingAgentWithoutPersistence() throws {
    let state = makeState()
    let thinkingTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Claude Code",
          command: "claude",
          icon: "claude",
          agentFamilyID: .claudeCode,
          sandboxEnabled: true
        ))
    )
    thinkingTab.agentActivityState = .thinking

    #expect(
      state.quitAgentSummary
        == WorkspaceQuitAgentSummary(warningCount: 1, keepRunningCount: 0, thinkingCount: 1))
  }

  @Test("quit summary ignores idle persistent agents")
  @MainActor
  func quitSummaryIgnoresIdlePersistentAgents() throws {
    let session = TerminalSessionReference(backendID: "test", sessionID: "idle-session")
    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex --yolo",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    tab.terminalSession = session

    #expect(state.quitAgentSummary == .empty)
  }

  @Test("quit summary counts thinking persistent agents")
  @MainActor
  func quitSummaryCountsThinkingPersistentAgents() throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let session = TerminalSessionReference(backendID: "test", sessionID: "thinking-session")
    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex --yolo",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    tab.terminalSession = session
    tab.agentActivityState = .thinking

    #expect(
      state.quitAgentSummary
        == WorkspaceQuitAgentSummary(warningCount: 1, keepRunningCount: 1, thinkingCount: 1))
  }

  @Test("persistent terminal launch uses the terminal session backend")
  @MainActor
  func persistentTerminalLaunchUsesTerminalSessionBackend() throws {
    let session = TerminalSessionReference(backendID: "test", sessionID: "launch-session")
    WorkspaceState.terminalSessionReferenceProvider = { _, _ in
      session
    }
    WorkspaceState.terminalSessionLaunchBuilder = Self.testTerminalSessionLaunchBuilder
    defer {
      WorkspaceState.terminalSessionReferenceProvider = { tabID, workspacePath in
        TerminalSessionBackends.reference(for: tabID, workspacePath: workspacePath)
      }
      WorkspaceState.terminalSessionLaunchBuilder = Self.defaultTerminalSessionLaunchBuilder
    }

    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex --yolo",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          resumeArgumentTemplate: "resume {{session_id}}",
          keepRunningWhileThinking: true
        ))
    )

    #expect(tab.terminalSession == session)
    #expect(tab.launch.processSpec.args.last?.contains("launch-session") == true)
    #expect(tab.launch.processSpec.args.last?.contains("codex --yolo") == true)
    #expect(tab.launch.processSpec.args.last?.contains("--remote") == false)
  }

  @Test("argon terminal session launch wraps attach in user shell")
  func argonTerminalSessionLaunchWrapsAttachInUserShell() throws {
    let tabID = UUID(uuidString: "8E0C2B1D-0CE1-40C4-8A8E-8F07E75FA597")!
    let reference = try #require(
      ArgonTerminalSessionBackend().reference(for: tabID, workspacePath: "/tmp/repo")
    )
    let storageDir = try #require(
      reference.context[TerminalSessionReferenceContextKey.storageDirectory]
    )
    let createLaunch = TerminalLaunchConfiguration.command(
      "codex --yolo",
      currentDirectory: "/tmp/repo",
      tabID: tabID,
      environment: [
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/zsh",
      ]
    )

    let launch = TerminalSessionBackends.attachLaunchConfiguration(
      reference: reference,
      createLaunch: createLaunch
    )

    #expect(storageDir.hasPrefix("/tmp/argon-ts-"))
    #expect(storageDir.contains("/p-"))
    #expect("\(storageDir)/\(reference.sessionID).sock".utf8.count < 104)
    #expect(launch.processSpec.executable == "/bin/zsh")
    #expect(Array(launch.processSpec.args.prefix(3)) == ["-i", "-l", "-c"])
    let attachCommand = launch.processSpec.args.last ?? ""
    #expect(attachCommand.contains(ArgonCLI.cliPath()))
    #expect(attachCommand.contains("'terminal' 'attach'"))
    #expect(attachCommand.contains("'--session-id' '\(reference.sessionID)'"))
    #expect(attachCommand.contains("'--storage-dir' '\(storageDir)'"))
    #expect(attachCommand.contains("/p-"))
    #expect(!attachCommand.contains("argon-terminal-sessions"))
    #expect(attachCommand.contains("'/bin/sh' '-lc'"))
    #expect(attachCommand.contains("codex --yolo"))
    #expect(launch.currentDirectory == "/tmp/repo")
    #expect(launch.environment["ARGON_TERMINAL_TAB_ID"] == tabID.uuidString.lowercased())
  }

  @Test("terminal sessions stop unless running persistence is preserved")
  @MainActor
  func terminalSessionsStopUnlessRunningAndPreserved() throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let session = TerminalSessionReference(backendID: "test", sessionID: "thinking")
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    defer {
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
    }

    let state = makeState()
    let thinkingTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    thinkingTab.terminalSession = session
    thinkingTab.agentActivityState = .thinking

    let idleSession = TerminalSessionReference(backendID: "test", sessionID: "idle")
    let idleTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    idleTab.terminalSession = idleSession

    let waitingSession = TerminalSessionReference(backendID: "test", sessionID: "waiting")
    let waitingTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    waitingTab.terminalSession = waitingSession
    waitingTab.agentActivityState = .waitingForHuman

    state.prepareTerminalSessionsForTermination(keepRunningAgentsAlive: true)
    #expect(thinkingTab.terminalSession == session)
    #expect(idleTab.terminalSession == nil)
    #expect(waitingTab.terminalSession == nil)
    #expect(stoppedSessions.sessions.map(\.sessionID).sorted() == ["idle", "waiting"])

    state.prepareTerminalSessionsForTermination(keepRunningAgentsAlive: false)
    #expect(thinkingTab.terminalSession == nil)
    #expect(idleTab.terminalSession == nil)
    #expect(waitingTab.terminalSession == nil)
    #expect(stoppedSessions.sessions.map(\.sessionID).sorted() == ["idle", "thinking", "waiting"])

    let regularState = makeState()
    let closeSession = TerminalSessionReference(backendID: "test", sessionID: "close")
    let closeTab = try #require(
      regularState.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    closeTab.terminalSession = closeSession
    regularState.closeTerminalTab(closeTab.id)
    #expect(stoppedSessions.sessions.map(\.sessionID).contains(closeSession.sessionID))

    let exitSession = TerminalSessionReference(backendID: "test", sessionID: "exit")
    let exitTab = try #require(
      regularState.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    exitTab.terminalSession = exitSession
    regularState.handleTerminalExit(exitTab.id, exitBehavior: .keepOpen)
    #expect(exitTab.terminalSession == nil)
    #expect(stoppedSessions.sessions.map(\.sessionID).contains(exitSession.sessionID))
  }

  @Test("persistent terminal sessions reattach when the server is still alive")
  @MainActor
  func persistentTerminalSessionsReattachWhenServerIsStillAlive() throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let session = TerminalSessionReference(backendID: "test", sessionID: "alive")
    let legacySession = TerminalSessionReference(backendID: "test", sessionID: "legacy-alive")
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    WorkspaceState.terminalSessionRunningChecker = { candidate in
      candidate == session || candidate == legacySession
    }
    defer {
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
      WorkspaceState.terminalSessionRunningChecker = { session in
        TerminalSessionBackends.isRunning(reference: session)
      }
    }

    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    tab.terminalSession = session
    let originalViewIdentity = tab.terminalViewIdentity

    state.handleTerminalExit(tab.id, exitBehavior: .keepOpen)

    #expect(tab.terminalSession == session)
    #expect(tab.isRunning)
    #expect(tab.terminalViewIdentity != originalViewIdentity)
    #expect(tab.terminalSessionReconnectCount == 1)
    #expect(stoppedSessions.sessions.isEmpty)

    state.handleTerminalExit(tab.id, exitBehavior: .keepOpen)
    #expect(tab.terminalSession == session)
    #expect(tab.terminalSessionReconnectCount == 2)
    #expect(stoppedSessions.sessions.isEmpty)

    let secondReconnectViewIdentity = tab.terminalViewIdentity

    state.handleTerminalExit(tab.id, exitBehavior: .keepOpen)
    #expect(tab.terminalSession == session)
    #expect(tab.isRunning)
    #expect(tab.terminalViewIdentity != secondReconnectViewIdentity)
    #expect(tab.terminalSessionReconnectCount == 3)
    #expect(stoppedSessions.sessions.isEmpty)

    let legacyTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: false
        ))
    )
    legacyTab.terminalSession = legacySession
    let legacyOriginalViewIdentity = legacyTab.terminalViewIdentity

    state.handleTerminalExit(legacyTab.id, exitBehavior: .keepOpen)

    #expect(legacyTab.terminalSession == legacySession)
    #expect(legacyTab.isRunning)
    #expect(legacyTab.terminalViewIdentity != legacyOriginalViewIdentity)
    #expect(legacyTab.terminalSessionReconnectCount == 1)
    #expect(stoppedSessions.sessions.isEmpty)
  }

  @Test("persistent terminal attach watchdog reattaches exited hosts")
  @MainActor
  func persistentTerminalAttachWatchdogReattachesExitedHosts() throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let session = TerminalSessionReference(backendID: "test", sessionID: "alive")
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    WorkspaceState.terminalSessionRunningChecker = { candidate in
      candidate == session
    }
    defer {
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
      WorkspaceState.terminalSessionRunningChecker = { session in
        TerminalSessionBackends.isRunning(reference: session)
      }
    }

    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    tab.terminalSession = session
    let originalViewIdentity = tab.terminalViewIdentity

    #expect(
      !state.recoverPersistentTerminalAttachIfExited(
        tab.id,
        processExited: false
      ))
    #expect(tab.terminalViewIdentity == originalViewIdentity)
    #expect(tab.terminalSessionReconnectCount == 0)

    #expect(
      state.recoverPersistentTerminalAttachIfExited(
        tab.id,
        processExited: true
      ))

    #expect(tab.terminalSession == session)
    #expect(tab.isRunning)
    #expect(tab.terminalViewIdentity != originalViewIdentity)
    #expect(tab.terminalSessionReconnectCount == 1)
    #expect(stoppedSessions.sessions.isEmpty)
  }

  @Test("stopping thinking agent tabs preserves them for lazy restore")
  @MainActor
  func stoppingThinkingAgentTabsPreservesThemForLazyRestore() async throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(false)
    defer { restoreExperiment() }

    let session = TerminalSessionReference(backendID: "test", sessionID: "stopped-thinking")
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionReferenceProvider = { _, _ in
      session
    }
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    WorkspaceState.commandStatusProvider = { commands in
      Dictionary(commands.map { ($0, true) }, uniquingKeysWith: { current, _ in current })
    }
    defer {
      WorkspaceState.terminalSessionReferenceProvider = { tabID, workspacePath in
        TerminalSessionBackends.reference(for: tabID, workspacePath: workspacePath)
      }
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
      WorkspaceState.commandStatusProvider = nil
    }

    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex --yolo",
          baseCommandDescription: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          yoloMode: true,
          yoloFlag: "--yolo",
          resumeArgumentTemplate: "resume {{session_id}}",
          resumeSessionID: "44444444-4444-4444-4444-444444444444",
          keepRunningWhileThinking: true
        ))
    )
    tab.agentActivityState = .thinking

    state.closeThinkingAgentTabs()

    #expect(stoppedSessions.sessions == [session])
    #expect(state.allTerminalTabs.isEmpty)

    let snapshot = state.persistedWindowSnapshot
    let persistedTabs = try #require(snapshot.terminalTabsByWorktreePath["/tmp/repo"])
    let persistedTab = try #require(persistedTabs.first { $0.id == tab.id })
    #expect(persistedTab.terminalSession == nil)
    #expect(persistedTab.resumeSessionID == "44444444-4444-4444-4444-444444444444")
    #expect(
      persistedTab.resumeCommandDescription
        == "codex --yolo resume '44444444-4444-4444-4444-444444444444'")

    state.prepareSelectionLoading(for: "/tmp/repo")
    #expect(await waitUntil { state.selectedTerminalTabs.contains { $0.id == tab.id } })

    let restoredTab = try #require(state.selectedTerminalTabs.first { $0.id == tab.id })
    #expect(restoredTab.resumeSessionID == "44444444-4444-4444-4444-444444444444")
    #expect(
      restoredTab.launch.processSpec.args.last?
        .contains("codex --yolo resume '44444444-4444-4444-4444-444444444444'") == true)
  }

  @Test("preserved terminal sessions survive the view detach during quit")
  @MainActor
  func preservedTerminalSessionsSurviveViewDetachDuringQuit() throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let session = TerminalSessionReference(backendID: "test", sessionID: "thinking")
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    defer {
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
    }

    let state = makeState()
    let tab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    tab.terminalSession = session
    tab.agentActivityState = .thinking

    state.prepareTerminalSessionsForTermination(keepRunningAgentsAlive: true)
    tab.isRunning = false
    state.handleTerminalExit(tab.id, exitBehavior: .autoClose)

    #expect(tab.terminalSession == session)
    #expect(tab.isRunning)
    #expect(state.allTerminalTabs.contains { $0 === tab })
    #expect(stoppedSessions.sessions.isEmpty)

    state.finishTerminalDetach()
    state.handleTerminalExit(tab.id, exitBehavior: .keepOpen)
    #expect(tab.terminalSession == nil)
    #expect(stoppedSessions.sessions == [session])
  }

  @Test("persisted snapshots mark running terminal sessions for restore")
  @MainActor
  func persistedSnapshotsMarkRunningTerminalSessionsForRestore() throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    WorkspaceState.terminalSessionReferenceProvider = { tabID, _ in
      TerminalSessionReference(
        backendID: "test",
        sessionID: "session-\(tabID.uuidString.lowercased())"
      )
    }
    defer {
      WorkspaceState.terminalSessionReferenceProvider = { tabID, workspacePath in
        TerminalSessionBackends.reference(for: tabID, workspacePath: workspacePath)
      }
    }

    let state = makeState()
    let thinkingTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )
    thinkingTab.agentActivityState = .thinking

    let idleTab = try #require(
      state.openAgentTab(
        WorkspaceAgentLaunchRequest(
          displayName: "Codex",
          command: "codex",
          icon: "codex",
          agentFamilyID: .codex,
          sandboxEnabled: true,
          keepRunningWhileThinking: true
        ))
    )

    let snapshot = state.persistedWindowSnapshot
    let tabs = try #require(snapshot.terminalTabsByWorktreePath["/tmp/repo"])
    let persistedThinkingTab = try #require(tabs.first { $0.id == thinkingTab.id })
    let persistedIdleTab = try #require(tabs.first { $0.id == idleTab.id })
    let thinkingSession = try #require(persistedThinkingTab.terminalSession)
    let idleSession = try #require(persistedIdleTab.terminalSession)

    #expect(TerminalSessionBackends.wasPreservedForRestore(reference: thinkingSession))
    #expect(!TerminalSessionBackends.wasPreservedForRestore(reference: idleSession))
    #expect(persistedThinkingTab.agentActivityState == .thinking)
    #expect(persistedIdleTab.keepsRunningAfterQuit == true)
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
    #expect(!json.contains("yoloFlag"))
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
  private func stubFastForwardMergeBackPerformer(
    _ performer:
      @escaping @Sendable (FastForwardMergeBackRequest) throws ->
      FastForwardMergeBackResult
  ) -> () -> Void {
    let previousPerformer = WorkspaceState.fastForwardMergeBackPerformer
    WorkspaceState.fastForwardMergeBackPerformer = performer
    return {
      WorkspaceState.fastForwardMergeBackPerformer = previousPerformer
    }
  }

  @MainActor
  private func setExperimentalPersistentAgentTerminalsForTest(_ enabled: Bool) -> () -> Void {
    let previous = UserDefaults.standard.object(
      forKey: AgentTerminalPersistenceExperimentSettings.enabledStorageKey
    )
    UserDefaults.standard.set(
      enabled,
      forKey: AgentTerminalPersistenceExperimentSettings.enabledStorageKey
    )
    return {
      if let previous {
        UserDefaults.standard.set(
          previous,
          forKey: AgentTerminalPersistenceExperimentSettings.enabledStorageKey
        )
      } else {
        UserDefaults.standard.removeObject(
          forKey: AgentTerminalPersistenceExperimentSettings.enabledStorageKey
        )
      }
    }
  }

  @MainActor
  private func isolateAgentSessionRestoreMetadataStoreForTest() -> () -> Void {
    let suiteName = "WorkspaceStateTests.agentSessionRestoreMetadata.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let previousDefaults = AgentSessionRestoreMetadataStore.userDefaults
    AgentSessionRestoreMetadataStore.userDefaults = defaults
    return {
      AgentSessionRestoreMetadataStore.userDefaults = previousDefaults
      defaults.removePersistentDomain(forName: suiteName)
    }
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

  private func write(agentControlResponse: WorkspaceAgentControlResponse, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(agentControlResponse)
    try data.write(to: url, options: .atomic)
  }

  private static func testTerminalSessionLaunchBuilder(
    session: TerminalSessionReference,
    createLaunch: TerminalLaunchConfiguration
  ) -> TerminalLaunchConfiguration {
    TerminalLaunchConfiguration.command(
      [
        "/usr/bin/test-attach",
        "attach",
        session.sessionID,
        createLaunch.shellCommand,
      ].map(TerminalLaunchConfiguration.shellQuote).joined(separator: " "),
      currentDirectory: createLaunch.currentDirectory,
      environment: createLaunch.environment
    )
  }

  private static func defaultTerminalSessionLaunchBuilder(
    session: TerminalSessionReference,
    createLaunch: TerminalLaunchConfiguration
  ) -> TerminalLaunchConfiguration {
    TerminalSessionBackends.attachLaunchConfiguration(
      reference: session,
      createLaunch: createLaunch
    )
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

final class TerminalSessionStopRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedSessions: [TerminalSessionReference] = []

  var sessions: [TerminalSessionReference] {
    lock.withLock {
      storedSessions
    }
  }

  func append(_ session: TerminalSessionReference) {
    lock.withLock {
      storedSessions.append(session)
    }
  }
}
