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
