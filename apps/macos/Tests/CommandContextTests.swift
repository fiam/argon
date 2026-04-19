import Foundation
import Testing

@testable import Argon

@Suite("CommandContext")
@MainActor
struct CommandContextTests {
  @Test("remembers the selected worktree path for sandbox settings")
  func remembersSelectedWorktreePath() {
    let context = CommandContext()
    let workspaceState = WorkspaceState(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo/worktrees/feature"
      )
    )

    context.activate(workspaceState: workspaceState)
    context.clear(workspaceState: workspaceState)

    #expect(context.sandboxSettingsRoot == "/tmp/repo/worktrees/feature")
    #expect(context.sandboxSettingsSource == .workspace)
  }

  @Test("remembers the review repo root for sandbox settings")
  func remembersReviewRepoRoot() {
    let context = CommandContext()
    let appState = AppState(sessionId: "session", repoRoot: "/tmp/repo")

    context.activate(appState: appState)
    context.clear(appState: appState)

    #expect(context.sandboxSettingsRoot == "/tmp/repo")
    #expect(context.sandboxSettingsSource == .review)
  }
}
