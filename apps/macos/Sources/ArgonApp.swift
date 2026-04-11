import SwiftUI

@main
struct ArgonApp: App {
  private static let cliReviewTarget = AppLaunchTarget.current()
  @FocusedValue(\.appState) private var focusedAppState
  @State private var recentProjects = RecentProjects()
  @State private var savedAgents = SavedAgentProfiles()
  @State private var agentAvailability = AgentAvailability()

  init() {
    AppSignalHandling.installEmbeddedTerminalHandlers()
  }

  var body: some Scene {
    // Welcome window (shown when app launches without CLI args)
    Window("Welcome to Argon", id: "welcome") {
      if let cliReviewTarget = Self.cliReviewTarget {
        ReviewWindowView(target: cliReviewTarget)
          .environment(recentProjects)
          .environment(savedAgents)
          .environment(agentAvailability)
          .task {
            recentProjects.add(repoRoot: cliReviewTarget.repoRoot)
          }
          .task(id: savedAgents.profiles) {
            agentAvailability.refresh(for: savedAgents.profiles)
          }
      } else {
        WelcomeView()
          .environment(recentProjects)
          .environment(savedAgents)
          .environment(agentAvailability)
          .task(id: savedAgents.profiles) {
            agentAvailability.refresh(for: savedAgents.profiles)
          }
      }
    }
    .defaultSize(
      width: Self.cliReviewTarget == nil ? 500 : 1100,
      height: Self.cliReviewTarget == nil ? 450 : 700
    )

    // Review windows (one per session)
    WindowGroup(for: ReviewTarget.self) { $target in
      if let target {
        ReviewWindowView(target: target)
          .environment(recentProjects)
          .environment(savedAgents)
          .environment(agentAvailability)
          .task(id: savedAgents.profiles) {
            agentAvailability.refresh(for: savedAgents.profiles)
          }
      }
    }
    .defaultSize(width: 1100, height: 700)
    .commands {
      // Find menu
      CommandGroup(replacing: .textEditing) {
        Button("Find in Diff") {
          focusedAppState?.toggleSearch()
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(focusedAppState == nil)

        Button("Filter Files") {
          focusedAppState?.focusFileFilter = true
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(focusedAppState == nil)

        Divider()

        Button("Dismiss") {
          focusedAppState?.dismissAll()
        }
        .keyboardShortcut(.escape, modifiers: [])
      }

      // Navigate menu
      CommandGroup(after: .toolbar) {
        Button("Next File") {
          focusedAppState?.navigateToNextFile()
        }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .disabled(focusedAppState == nil)

        Button("Previous File") {
          focusedAppState?.navigateToPreviousFile()
        }
        .keyboardShortcut(.upArrow, modifiers: .command)
        .disabled(focusedAppState == nil)

        Divider()

        Button("Unified View") {
          focusedAppState?.diffMode = .unified
        }
        .keyboardShortcut("1", modifiers: .command)
        .disabled(focusedAppState == nil)

        Button("Side by Side View") {
          focusedAppState?.diffMode = .sideBySide
        }
        .keyboardShortcut("2", modifiers: .command)
        .disabled(focusedAppState == nil)
      }
    }

    Settings {
      SettingsView()
        .environment(savedAgents)
        .environment(agentAvailability)
        .task(id: savedAgents.profiles) {
          agentAvailability.refresh(for: savedAgents.profiles)
        }
    }
  }
}
