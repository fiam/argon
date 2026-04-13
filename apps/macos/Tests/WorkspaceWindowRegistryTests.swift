import AppKit
import Foundation
import Testing

@testable import Argon

@Suite("WorkspaceWindowRegistry")
struct WorkspaceWindowRegistryTests {

  @Test("opening the same repo root while a window is pending does not request a duplicate window")
  @MainActor
  func openingPendingRepoRootDoesNotRequestDuplicateWindow() {
    let registry = WorkspaceWindowRegistry()
    let initialTarget = makeTarget(selectedWorktreePath: "/tmp/repo")
    let updatedTarget = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-a")
    var openedTargets: [WorkspaceTarget] = []

    registry.open(target: initialTarget) { target in
      openedTargets.append(target)
    }
    registry.open(target: updatedTarget) { target in
      openedTargets.append(target)
    }

    #expect(openedTargets == [initialTarget])

    let state = WorkspaceState(target: initialTarget)
    state.isLoading = true
    let window = NSWindow()

    registry.register(window: window, workspaceState: state, repoRoot: initialTarget.repoRoot)

    #expect(state.selectedWorktreePath == updatedTarget.selectedWorktreePath)
    #expect(state.launchWarningMessage?.contains(initialTarget.repoRoot) == true)
  }

  @Test(
    "opening an already opened repo root focuses the existing workspace instead of opening a new one"
  )
  @MainActor
  func openingExistingRepoRootReusesWindow() {
    let registry = WorkspaceWindowRegistry()
    let initialTarget = makeTarget(selectedWorktreePath: "/tmp/repo")
    let updatedTarget = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = WorkspaceState(target: initialTarget)
    state.isLoading = true
    let window = NSWindow()
    var openCount = 0

    registry.register(window: window, workspaceState: state, repoRoot: initialTarget.repoRoot)
    registry.open(target: updatedTarget) { _ in
      openCount += 1
    }

    #expect(openCount == 0)
    #expect(state.selectedWorktreePath == updatedTarget.selectedWorktreePath)
    #expect(state.launchWarningMessage?.contains(updatedTarget.selectedWorktreePath ?? "") == true)
  }

  private func makeTarget(selectedWorktreePath: String) -> WorkspaceTarget {
    WorkspaceTarget(
      repoRoot: "/tmp/repo",
      repoCommonDir: "/tmp/repo/.git",
      selectedWorktreePath: selectedWorktreePath
    )
  }
}
