import SwiftUI

struct ReviewWindowView: View {
  @Environment(CommandContext.self) private var commandContext
  @Environment(ReviewWindowRegistry.self) private var reviewWindowRegistry
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
      .background {
        WindowKeyObserver(
          onBecomeKey: { commandContext.activate(appState: appState) },
          onResignKey: { commandContext.clear(appState: appState) }
        )
      }
      .onAppear {
        reviewWindowRegistry.markOpened(repoRoot: target.repoRoot)
        UITestAutomationSignal.write(
          "review-window-appeared",
          to: UITestAutomationConfig.current().signalFilePath
        )
      }
      .onDisappear {
        reviewWindowRegistry.markClosed(repoRoot: target.repoRoot)
      }
  }
}
