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

enum WorkspaceAgentActivityState: Equatable, Sendable {
  case idle
  case thinking
  case waitingForHuman
}

struct WorktreeAgentActivitySummary: Equatable, Sendable {
  let waitingForHumanCount: Int
  let thinkingCount: Int
  let runningAgentCount: Int

  static let empty = WorktreeAgentActivitySummary(
    waitingForHumanCount: 0,
    thinkingCount: 0,
    runningAgentCount: 0
  )
}

struct WorkspaceAgentLaunchRequest: Sendable {
  let displayName: String
  let command: String
  let baseCommandDescription: String
  let launchCommandOverride: String?
  let icon: String
  let agentFamilyID: AgentFamilyID?
  let sandboxEnabled: Bool
  let yoloMode: Bool
  let yoloFlag: String
  let resumeArgumentTemplate: String
  let resumeSessionID: String?
  let keepRunningWhileThinking: Bool
  let useHashedDuplicateSuffix: Bool
  let isRestorableAfterRelaunch: Bool
  let additionalWritableRoots: [String]

  init(
    displayName: String,
    command: String,
    baseCommandDescription: String? = nil,
    launchCommandOverride: String? = nil,
    icon: String,
    agentFamilyID: AgentFamilyID? = nil,
    sandboxEnabled: Bool,
    yoloMode: Bool = false,
    yoloFlag: String = "",
    resumeArgumentTemplate: String = "",
    resumeSessionID: String? = nil,
    keepRunningWhileThinking: Bool = false,
    useHashedDuplicateSuffix: Bool = false,
    isRestorableAfterRelaunch: Bool = true,
    additionalWritableRoots: [String] = []
  ) {
    self.displayName = displayName
    self.command = command
    self.baseCommandDescription = baseCommandDescription ?? command
    self.launchCommandOverride = launchCommandOverride
    self.icon = icon
    self.agentFamilyID = agentFamilyID
    self.sandboxEnabled = sandboxEnabled
    self.yoloMode = yoloMode
    self.yoloFlag = yoloFlag
    self.resumeArgumentTemplate = resumeArgumentTemplate
    self.resumeSessionID = resumeSessionID
    self.keepRunningWhileThinking = keepRunningWhileThinking
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
      let effectiveYoloMode = yoloMode && !profile.yoloFlag.isEmpty
      return WorkspaceAgentLaunchRequest(
        displayName: profile.name,
        command: profile.fullCommand(
          yolo: yoloMode,
          sandboxed: sandboxEnabled,
          prompt: prompt
        ),
        baseCommandDescription: profile.command,
        icon: profile.icon,
        agentFamilyID: profile.familyID,
        sandboxEnabled: sandboxEnabled,
        yoloMode: effectiveYoloMode,
        yoloFlag: profile.yoloFlag,
        resumeArgumentTemplate: profile.resumeArgumentTemplate,
        keepRunningWhileThinking:
          AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence,
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
        baseCommandDescription: command,
        icon: icon,
        agentFamilyID: nil,
        sandboxEnabled: sandboxEnabled,
        yoloMode: false,
        yoloFlag: "",
        resumeArgumentTemplate: "",
        keepRunningWhileThinking:
          AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence,
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
  let baseCommandDescription: String
  let kind: WorkspaceTerminalKind
  let agentFamilyID: AgentFamilyID?
  let launch: TerminalLaunchConfiguration
  let createdAt: Date
  let isSandboxed: Bool
  let yoloMode: Bool
  let yoloFlag: String
  let writableRoots: [String]
  let isRestorableAfterRelaunch: Bool
  let resumeArgumentTemplate: String
  let keepsRunningAfterQuit: Bool
  var terminalSession: TerminalSessionReference?
  var resumeSessionID: String?
  var resumeCommandDescription: String?
  var isRunning: Bool
  var hasAttention: Bool
  var isShowingBellIndicator: Bool
  var agentActivityState: WorkspaceAgentActivityState
  var lastObservedTerminalTitle: String?
  var lastDeselectedAt: Date?
  var suppressAttentionUntil: Date?

  init(
    id: UUID = UUID(),
    worktreePath: String,
    worktreeLabel: String,
    title: String,
    commandDescription: String,
    baseCommandDescription: String? = nil,
    kind: WorkspaceTerminalKind,
    agentFamilyID: AgentFamilyID? = nil,
    launch: TerminalLaunchConfiguration,
    createdAt: Date = Date(),
    isSandboxed: Bool = false,
    yoloMode: Bool = false,
    yoloFlag: String = "",
    writableRoots: [String] = [],
    isRestorableAfterRelaunch: Bool = true,
    resumeArgumentTemplate: String = "",
    keepsRunningAfterQuit: Bool = false,
    terminalSession: TerminalSessionReference? = nil,
    resumeSessionID: String? = nil,
    resumeCommandDescription: String? = nil,
    isRunning: Bool = true,
    hasAttention: Bool = false,
    isShowingBellIndicator: Bool = false,
    agentActivityState: WorkspaceAgentActivityState = .idle,
    lastObservedTerminalTitle: String? = nil,
    lastDeselectedAt: Date? = nil,
    suppressAttentionUntil: Date? = nil
  ) {
    self.id = id
    self.worktreePath = worktreePath
    self.worktreeLabel = worktreeLabel
    self.title = title
    self.commandDescription = commandDescription
    self.baseCommandDescription = baseCommandDescription ?? commandDescription
    self.kind = kind
    self.agentFamilyID = agentFamilyID
    self.launch = launch
    self.createdAt = createdAt
    self.isSandboxed = isSandboxed
    self.yoloMode = yoloMode
    self.yoloFlag = yoloFlag
    self.writableRoots = writableRoots
    self.isRestorableAfterRelaunch = isRestorableAfterRelaunch
    self.resumeArgumentTemplate = resumeArgumentTemplate
    self.keepsRunningAfterQuit = keepsRunningAfterQuit
    self.terminalSession = terminalSession
    self.resumeSessionID = resumeSessionID
    self.resumeCommandDescription = resumeCommandDescription
    self.isRunning = isRunning
    self.hasAttention = hasAttention
    self.isShowingBellIndicator = isShowingBellIndicator
    self.agentActivityState = agentActivityState
    self.lastObservedTerminalTitle = lastObservedTerminalTitle
    self.lastDeselectedAt = lastDeselectedAt
    self.suppressAttentionUntil = suppressAttentionUntil
  }
}

extension ReviewerAgentInstance: TerminalProcessControlling {}

extension WorkspaceTerminalTab {
  var shouldWarnBeforeQuit: Bool {
    guard case .agent = kind else { return false }
    return isRunning && agentActivityState == .thinking
  }

  var shouldKeepRunningAcrossQuit: Bool {
    keepsRunningAfterQuit
      && AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence
      && terminalSession != nil
      && isRunning
  }

  var shouldKeepTerminalSessionAliveAcrossQuit: Bool {
    shouldKeepRunningAcrossQuit && agentActivityState == .thinking
  }

  func shouldSuppressAttention(at date: Date = Date()) -> Bool {
    guard let suppressAttentionUntil else { return false }
    guard date < suppressAttentionUntil else {
      self.suppressAttentionUntil = nil
      return false
    }
    return true
  }
}

struct WorkspaceQuitAgentSummary: Equatable, Sendable {
  let warningCount: Int
  let keepRunningCount: Int
  let thinkingCount: Int

  static let empty = WorkspaceQuitAgentSummary(
    warningCount: 0,
    keepRunningCount: 0,
    thinkingCount: 0
  )

  var needsPrompt: Bool {
    warningCount > 0
  }
}
