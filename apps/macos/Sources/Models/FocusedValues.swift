import SwiftUI

struct FocusedAppStateKey: FocusedValueKey {
  typealias Value = AppState
}

struct FocusedWorkspaceStateKey: FocusedValueKey {
  typealias Value = WorkspaceState
}

extension FocusedValues {
  var appState: AppState? {
    get { self[FocusedAppStateKey.self] }
    set { self[FocusedAppStateKey.self] = newValue }
  }

  var workspaceState: WorkspaceState? {
    get { self[FocusedWorkspaceStateKey.self] }
    set { self[FocusedWorkspaceStateKey.self] = newValue }
  }
}
