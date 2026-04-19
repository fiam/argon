import Foundation
import Observation

enum SandboxSettingsFocusSource: String, Sendable {
  case workspace
  case review

  var label: String {
    switch self {
    case .workspace:
      "workspace"
    case .review:
      "review"
    }
  }
}

@MainActor
@Observable
final class CommandContext {
  var activeWorkspaceState: WorkspaceState?
  var activeAppState: AppState?
  private(set) var lastFocusedSandboxRoot: String?
  private(set) var lastFocusedSandboxSource: SandboxSettingsFocusSource?

  var sandboxSettingsRoot: String? {
    if let activeWorkspaceState {
      sandboxRoot(for: activeWorkspaceState)
    } else if let repoRoot = activeAppState?.repoRoot {
      repoRoot
    } else {
      lastFocusedSandboxRoot
    }
  }

  var sandboxSettingsSource: SandboxSettingsFocusSource? {
    if activeWorkspaceState != nil {
      .workspace
    } else if activeAppState != nil {
      .review
    } else {
      lastFocusedSandboxSource
    }
  }

  func activate(workspaceState: WorkspaceState) {
    activeWorkspaceState = workspaceState
    activeAppState = nil
    remember(workspaceState: workspaceState)
  }

  func activate(appState: AppState) {
    activeAppState = appState
    activeWorkspaceState = nil
    remember(appState: appState)
  }

  func clear(workspaceState: WorkspaceState) {
    if activeWorkspaceState === workspaceState {
      remember(workspaceState: workspaceState)
      activeWorkspaceState = nil
    }
  }

  func clear(appState: AppState) {
    if activeAppState === appState {
      remember(appState: appState)
      activeAppState = nil
    }
  }

  private func remember(workspaceState: WorkspaceState) {
    lastFocusedSandboxRoot = sandboxRoot(for: workspaceState)
    lastFocusedSandboxSource = .workspace
  }

  private func remember(appState: AppState) {
    guard let repoRoot = appState.repoRoot else { return }
    lastFocusedSandboxRoot = repoRoot
    lastFocusedSandboxSource = .review
  }

  private func sandboxRoot(for workspaceState: WorkspaceState) -> String {
    workspaceState.normalizedSelectedWorktreePath
      ?? workspaceState.target.selectedWorktreePath
      ?? workspaceState.target.repoRoot
  }
}
