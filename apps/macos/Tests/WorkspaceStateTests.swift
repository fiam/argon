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

  @Test("shell exit behavior can auto-close shell tabs without closing agent tabs")
  @MainActor
  func shellExitBehaviorCanAutoCloseShellTabsWithoutClosingAgentTabs() async throws {
    let state = makeState()
    state.openShellTab()
    let shellID = try #require(state.selectedTerminalTab?.id)

    state.handleTerminalExit(shellID, shellExitBehavior: .closeTab)
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

    state.handleTerminalExit(agentID, shellExitBehavior: .closeTab)
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

  @Test("sandboxed shell tabs use sandbox exec and expose sandbox identity")
  @MainActor
  func sandboxedShellTabsUseSandboxExecAndExposeSandboxIdentity() {
    let state = makeState()

    state.openShellTab(sandboxed: true)

    let tab = state.selectedTerminalTab
    #expect(tab?.title == "Sandboxed Shell 1")
    #expect(tab?.isSandboxed == true)
    #expect(tab?.commandDescription.contains("Sandboxed") == true)
    #expect(tab?.launch.processSpec.executable == ArgonCLI.cliPath())
    #expect(tab?.launch.processSpec.args.starts(with: ["sandbox", "exec"]) == true)
    #expect(tab?.launch.processSpec.args.contains("/tmp/repo") == true)
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
      hasConflicts: false
    )

    state.applyRefreshedWorktree(refreshed, for: "/tmp/repo/feature")

    #expect(state.summary(for: "/tmp/repo/feature").fileCount == 1)
    #expect(state.selectedSummary.fileCount == 2)
    #expect(state.selectedFiles.first?.displayPath == "README.md")
    #expect(state.selectedDiffStat == "2 files changed")
  }

  @MainActor
  private func makeState() -> WorkspaceState {
    let target = WorkspaceTarget(
      repoRoot: "/tmp/repo",
      repoCommonDir: "/tmp/repo/.git",
      selectedWorktreePath: "/tmp/repo"
    )
    let state = WorkspaceState(target: target)
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
}
