import SwiftUI

@main
struct ArgonApp: App {
  @State private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(appState)
    }
    .defaultSize(width: 1100, height: 700)
    .commands {
      // Find menu
      CommandGroup(replacing: .textEditing) {
        Button("Find in Diff") {
          appState.toggleSearch()
        }
        .keyboardShortcut("f", modifiers: .command)

        Button("Filter Files") {
          appState.focusFileFilter = true
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])

        Divider()

        Button("Dismiss") {
          appState.dismissAll()
        }
        .keyboardShortcut(.escape, modifiers: [])
      }

      // Navigate menu
      CommandGroup(after: .toolbar) {
        Button("Next File") {
          appState.navigateToNextFile()
        }
        .keyboardShortcut(.downArrow, modifiers: .command)

        Button("Previous File") {
          appState.navigateToPreviousFile()
        }
        .keyboardShortcut(.upArrow, modifiers: .command)

        Divider()

        Button("Unified View") {
          appState.diffMode = .unified
        }
        .keyboardShortcut("1", modifiers: .command)

        Button("Side by Side View") {
          appState.diffMode = .sideBySide
        }
        .keyboardShortcut("2", modifiers: .command)
      }
    }
  }
}
