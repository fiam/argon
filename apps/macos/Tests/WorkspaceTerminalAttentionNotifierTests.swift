import Foundation
import Testing

@testable import Argon

@Suite("WorkspaceTerminalAttentionNotifier")
struct WorkspaceTerminalAttentionNotifierTests {
  @Test("bell notifications include the workspace and tab")
  @MainActor
  func bellNotificationsIncludeTheWorkspaceAndTab() {
    let tab = makeTab(title: "Codex", worktreeLabel: "feature/login")

    let display = WorkspaceTerminalAttentionNotifier.notificationDisplay(
      for: .bell,
      repoRoot: "/tmp/argon",
      tab: tab
    )

    #expect(display?.title == "Terminal bell")
    #expect(display?.subtitle == "argon • Codex")
    #expect(display?.body == "Bell in feature/login.")
  }

  @Test("command finished notifications keep workspace context")
  @MainActor
  func commandFinishedNotificationsKeepWorkspaceContext() {
    let tab = makeTab(title: "Shell 1", worktreeLabel: "main")

    let display = WorkspaceTerminalAttentionNotifier.notificationDisplay(
      for: .commandFinished(exitCode: 0, durationNanoseconds: 2_000_000_000),
      repoRoot: "/tmp/argon",
      tab: tab
    )

    #expect(display?.title == "Shell 1 finished command")
    #expect(display?.subtitle == "argon • Shell 1")
    #expect(display?.body.contains("Command exited with code 0 after") == true)
  }

  @MainActor
  private func makeTab(
    title: String,
    worktreeLabel: String
  ) -> WorkspaceTerminalTab {
    WorkspaceTerminalTab(
      worktreePath: "/tmp/argon",
      worktreeLabel: worktreeLabel,
      title: title,
      commandDescription: "echo hi",
      kind: .agent(profileName: title, icon: "codex"),
      launch: .command("echo hi", currentDirectory: "/tmp/argon")
    )
  }
}
