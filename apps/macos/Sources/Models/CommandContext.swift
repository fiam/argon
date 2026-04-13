import Foundation
import Observation

@MainActor
@Observable
final class CommandContext {
  var activeWorkspaceState: WorkspaceState?
  var activeAppState: AppState?

  func activate(workspaceState: WorkspaceState) {
    activeWorkspaceState = workspaceState
    activeAppState = nil
  }

  func activate(appState: AppState) {
    activeAppState = appState
    activeWorkspaceState = nil
  }

  func clear(workspaceState: WorkspaceState) {
    if activeWorkspaceState === workspaceState {
      activeWorkspaceState = nil
    }
  }

  func clear(appState: AppState) {
    if activeAppState === appState {
      activeAppState = nil
    }
  }
}
