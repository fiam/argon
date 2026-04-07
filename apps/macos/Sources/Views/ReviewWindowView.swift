import SwiftUI

struct ReviewWindowView: View {
  let target: ReviewTarget
  @State private var appState: AppState

  init(target: ReviewTarget) {
    self.target = target
    self._appState = State(
      initialValue: AppState(
        sessionId: target.sessionId,
        repoRoot: target.repoRoot
      ))
  }

  var body: some View {
    ContentView()
      .environment(appState)
      .focusedValue(\.appState, appState)
  }
}
