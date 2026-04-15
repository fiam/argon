import AppKit
import SwiftUI

struct ReviewWindowView: View {
  @Environment(CommandContext.self) private var commandContext
  @Environment(ReviewWindowRegistry.self) private var reviewWindowRegistry
  let target: ReviewTarget
  @State private var appState: AppState
  @State private var attachedWindow: NSWindow?

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
          onResignKey: { commandContext.clear(appState: appState) },
          onWindowChange: { window in
            handleWindowChange(window)
          }
        )
      }
      .onAppear {
        UITestAutomationSignal.write(
          "review-window-appeared",
          to: UITestAutomationConfig.current().signalFilePath
        )
      }
  }

  private func handleWindowChange(_ window: NSWindow?) {
    if let window {
      guard attachedWindow !== window else { return }
      attachedWindow = window
      reviewWindowRegistry.register(window: window, repoRoot: target.repoRoot)
      return
    }

    guard let attachedWindow else { return }
    reviewWindowRegistry.unregister(window: attachedWindow, repoRoot: target.repoRoot)
    self.attachedWindow = nil
  }
}
