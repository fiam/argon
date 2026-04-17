import AppKit
import SwiftUI

@main
struct ArgonApp: App {
  private static let cliLaunchRequest = AppLaunchTarget.current()
  private static let launchAppearance = LaunchAppearance.current()
  @FocusedValue(\.appState) private var focusedAppState
  @State private var recentProjects = RecentProjects()
  @State private var savedAgents = SavedAgentProfiles()
  @State private var agentAvailability = AgentAvailability()
  @State private var commandContext = CommandContext()
  @State private var reviewWindowRegistry = ReviewWindowRegistry()
  @State private var workspaceWindowRegistry = WorkspaceWindowRegistry()

  init() {
    AppSignalHandling.installEmbeddedTerminalHandlers()
    if let appearance = Self.launchAppearance.nsAppearance {
      NSApplication.shared.appearance = appearance
    }
  }

  var body: some Scene {
    Window("Argon", id: "welcome") {
      WelcomeView(launchRequest: Self.cliLaunchRequest)
        .environment(recentProjects)
        .environment(savedAgents)
        .environment(agentAvailability)
        .environment(commandContext)
        .environment(reviewWindowRegistry)
        .environment(workspaceWindowRegistry)
        .preferredColorScheme(Self.launchAppearance.colorScheme)
        .task(id: savedAgents.profiles) {
          agentAvailability.refresh(for: savedAgents.profiles)
        }
    }
    .defaultSize(width: Self.cliLaunchRequest == nil ? 560 : 300, height: 420)

    WindowGroup(for: WorkspaceTarget.self) { $target in
      if let target {
        workspaceRoot(target: target)
      }
    }
    .defaultSize(width: 1180, height: 700)

    // Review windows (one per session)
    WindowGroup(for: ReviewTarget.self) { $target in
      if let target {
        reviewRoot(target: target)
      }
    }
    .defaultSize(width: 980, height: 700)
    .commands {
      WorkspaceFileCommands(
        recentProjects: recentProjects,
        commandContext: commandContext,
        workspaceWindowRegistry: workspaceWindowRegistry
      )

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

  @ViewBuilder
  private func workspaceRoot(target: WorkspaceTarget) -> some View {
    WorkspaceWindowView(target: target)
      .environment(recentProjects)
      .environment(savedAgents)
      .environment(agentAvailability)
      .environment(commandContext)
      .environment(reviewWindowRegistry)
      .environment(workspaceWindowRegistry)
      .preferredColorScheme(Self.launchAppearance.colorScheme)
      .task {
        recentProjects.add(repoRoot: target.repoRoot)
      }
      .task(id: savedAgents.profiles) {
        agentAvailability.refresh(for: savedAgents.profiles)
      }
  }

  @ViewBuilder
  private func reviewRoot(target: ReviewTarget) -> some View {
    ReviewWindowView(target: target)
      .environment(recentProjects)
      .environment(savedAgents)
      .environment(agentAvailability)
      .environment(commandContext)
      .environment(reviewWindowRegistry)
      .preferredColorScheme(Self.launchAppearance.colorScheme)
      .task(id: savedAgents.profiles) {
        agentAvailability.refresh(for: savedAgents.profiles)
      }
  }
}

private struct WorkspaceFileCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  let recentProjects: RecentProjects
  let commandContext: CommandContext
  let workspaceWindowRegistry: WorkspaceWindowRegistry

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button {
        pickDirectory()
      } label: {
        Label("Open Directory…", systemImage: "folder")
      }
      .keyboardShortcut("o", modifiers: .command)

      Divider()

      Button {
        commandContext.activeWorkspaceState?.presentAgentLaunchSheet()
      } label: {
        Label("New Agent Tab…", systemImage: "sparkles.rectangle.stack")
      }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(commandContext.activeWorkspaceState?.selectedWorktree == nil)

      Button {
        commandContext.activeWorkspaceState?.openShellTab()
      } label: {
        Label("New Shell Tab", systemImage: "terminal")
      }
      .keyboardShortcut("t", modifiers: [.command, .shift])
      .disabled(commandContext.activeWorkspaceState?.selectedWorktree == nil)

      Button {
        commandContext.activeWorkspaceState?.openShellTab(sandboxed: false)
      } label: {
        Label("New Privileged Shell Tab", systemImage: "lock.open")
      }
      .keyboardShortcut("t", modifiers: [.command, .shift, .option])
      .disabled(commandContext.activeWorkspaceState?.selectedWorktree == nil)
    }
  }

  private func pickDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a Git repository or worktree"

    guard panel.runModal() == .OK, let url = panel.url else { return }
    openProject(repoRoot: url.path)
  }

  private func openProject(repoRoot: String) {
    Task {
      do {
        let target = try await Task.detached {
          try GitService.resolveWorkspaceTarget(path: repoRoot)
        }.value

        recentProjects.add(repoRoot: target.repoRoot)
        await MainActor.run {
          workspaceWindowRegistry.open(target: target) { target in
            openWindow(value: target)
          }
        }
      } catch {
        presentOpenError(error)
      }
    }
  }

  private func presentOpenError(_ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Unable to Open Repository"
    alert.informativeText = error.localizedDescription
    alert.runModal()
  }
}

private enum LaunchAppearance {
  case system
  case light
  case dark

  static func current() -> Self {
    guard let rawValue = ProcessInfo.processInfo.environment["ARGON_UI_MODE"]?.lowercased()
    else {
      return .system
    }

    switch rawValue {
    case "clear", "light", "aqua":
      return .light
    case "dark":
      return .dark
    default:
      return .system
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system:
      nil
    case .light:
      .light
    case .dark:
      .dark
    }
  }

  var nsAppearance: NSAppearance? {
    switch self {
    case .system:
      nil
    case .light:
      NSAppearance(named: .aqua)
    case .dark:
      NSAppearance(named: .darkAqua)
    }
  }
}
