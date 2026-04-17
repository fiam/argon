import Foundation

@MainActor
protocol TerminalProcessControlling: AnyObject {
  var isRunning: Bool { get set }
}

enum WorkspaceTerminalKind: Equatable, Sendable {
  case agent(profileName: String, icon: String)
  case shell

  var iconName: String {
    switch self {
    case .agent(_, let icon):
      icon
    case .shell:
      "terminal"
    }
  }
}

struct WorkspaceAgentLaunchRequest: Sendable {
  let displayName: String
  let command: String
  let icon: String
  let sandboxEnabled: Bool
  let useHashedDuplicateSuffix: Bool

  init(
    displayName: String,
    command: String,
    icon: String,
    sandboxEnabled: Bool,
    useHashedDuplicateSuffix: Bool = false
  ) {
    self.displayName = displayName
    self.command = command
    self.icon = icon
    self.sandboxEnabled = sandboxEnabled
    self.useHashedDuplicateSuffix = useHashedDuplicateSuffix
  }
}

enum WorkspaceAgentLaunchSource: Sendable {
  case savedProfile(SavedAgentProfile, yoloMode: Bool)
  case custom(displayName: String, command: String, icon: String)
}

struct WorkspaceAgentLaunchOptions: Sendable {
  let source: WorkspaceAgentLaunchSource
  let sandboxEnabled: Bool

  func buildRequest(prompt: String? = nil) -> WorkspaceAgentLaunchRequest {
    switch source {
    case .savedProfile(let profile, let yoloMode):
      return WorkspaceAgentLaunchRequest(
        displayName: profile.name,
        command: profile.fullCommand(
          yolo: yoloMode,
          sandboxed: sandboxEnabled,
          prompt: prompt
        ),
        icon: profile.icon,
        sandboxEnabled: sandboxEnabled,
        useHashedDuplicateSuffix: false
      )
    case .custom(let displayName, let command, let icon):
      return WorkspaceAgentLaunchRequest(
        displayName: displayName,
        command: renderAgentCommand(
          baseCommand: command,
          promptArgumentTemplate: "",
          prompt: prompt
        ),
        icon: icon,
        sandboxEnabled: sandboxEnabled,
        useHashedDuplicateSuffix: true
      )
    }
  }
}

@MainActor
@Observable
final class WorkspaceTerminalTab: Identifiable, TerminalProcessControlling {
  let id: UUID
  let worktreePath: String
  let worktreeLabel: String
  let title: String
  let commandDescription: String
  let kind: WorkspaceTerminalKind
  let launch: TerminalLaunchConfiguration
  let createdAt: Date
  let isSandboxed: Bool
  var isRunning: Bool

  init(
    id: UUID = UUID(),
    worktreePath: String,
    worktreeLabel: String,
    title: String,
    commandDescription: String,
    kind: WorkspaceTerminalKind,
    launch: TerminalLaunchConfiguration,
    createdAt: Date = Date(),
    isSandboxed: Bool = false,
    isRunning: Bool = true
  ) {
    self.id = id
    self.worktreePath = worktreePath
    self.worktreeLabel = worktreeLabel
    self.title = title
    self.commandDescription = commandDescription
    self.kind = kind
    self.launch = launch
    self.createdAt = createdAt
    self.isSandboxed = isSandboxed
    self.isRunning = isRunning
  }
}

extension ReviewerAgentInstance: TerminalProcessControlling {}
