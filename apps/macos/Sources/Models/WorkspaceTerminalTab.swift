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
  let resumeArgumentTemplate: String
  let useHashedDuplicateSuffix: Bool
  let isRestorableAfterRelaunch: Bool
  let additionalWritableRoots: [String]

  init(
    displayName: String,
    command: String,
    icon: String,
    sandboxEnabled: Bool,
    resumeArgumentTemplate: String = "",
    useHashedDuplicateSuffix: Bool = false,
    isRestorableAfterRelaunch: Bool = true,
    additionalWritableRoots: [String] = []
  ) {
    self.displayName = displayName
    self.command = command
    self.icon = icon
    self.sandboxEnabled = sandboxEnabled
    self.resumeArgumentTemplate = resumeArgumentTemplate
    self.useHashedDuplicateSuffix = useHashedDuplicateSuffix
    self.isRestorableAfterRelaunch = isRestorableAfterRelaunch
    self.additionalWritableRoots = additionalWritableRoots
  }
}

enum WorkspaceAgentLaunchSource: Sendable {
  case savedProfile(SavedAgentProfile, yoloMode: Bool)
  case custom(displayName: String, command: String, icon: String)
}

struct WorkspaceAgentLaunchOptions: Sendable {
  let source: WorkspaceAgentLaunchSource
  let sandboxEnabled: Bool

  func buildRequest(
    prompt: String? = nil,
    additionalWritableRoots: [String] = []
  ) -> WorkspaceAgentLaunchRequest {
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
        resumeArgumentTemplate: profile.resumeArgumentTemplate,
        useHashedDuplicateSuffix: false,
        isRestorableAfterRelaunch: prompt == nil,
        additionalWritableRoots: additionalWritableRoots
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
        resumeArgumentTemplate: "",
        useHashedDuplicateSuffix: true,
        isRestorableAfterRelaunch: prompt == nil,
        additionalWritableRoots: additionalWritableRoots
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
  let writableRoots: [String]
  let isRestorableAfterRelaunch: Bool
  let resumeArgumentTemplate: String
  var resumeSessionID: String?
  var resumeCommandDescription: String?
  var isRunning: Bool
  var hasAttention: Bool
  var isShowingBellIndicator: Bool
  var lastDeselectedAt: Date?

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
    writableRoots: [String] = [],
    isRestorableAfterRelaunch: Bool = true,
    resumeArgumentTemplate: String = "",
    resumeSessionID: String? = nil,
    resumeCommandDescription: String? = nil,
    isRunning: Bool = true,
    hasAttention: Bool = false,
    isShowingBellIndicator: Bool = false,
    lastDeselectedAt: Date? = nil
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
    self.writableRoots = writableRoots
    self.isRestorableAfterRelaunch = isRestorableAfterRelaunch
    self.resumeArgumentTemplate = resumeArgumentTemplate
    self.resumeSessionID = resumeSessionID
    self.resumeCommandDescription = resumeCommandDescription
    self.isRunning = isRunning
    self.hasAttention = hasAttention
    self.isShowingBellIndicator = isShowingBellIndicator
    self.lastDeselectedAt = lastDeselectedAt
  }
}

extension ReviewerAgentInstance: TerminalProcessControlling {}
