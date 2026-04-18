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
}
