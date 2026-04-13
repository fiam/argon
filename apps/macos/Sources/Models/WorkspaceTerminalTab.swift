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
