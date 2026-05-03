import Foundation

struct PersistedWorkspaceWindowSnapshot: Codable, Equatable {
  let target: WorkspaceTarget
  let terminalTabsByWorktreePath: [String: [PersistedWorkspaceTerminalTab]]
  let selectedTerminalTabIDsByWorktreePath: [String: UUID]
  let reviewSummaryDraftsByWorktreePath: [String: WorkspaceReviewSummaryDraft]

  init(
    target: WorkspaceTarget,
    terminalTabsByWorktreePath: [String: [PersistedWorkspaceTerminalTab]],
    selectedTerminalTabIDsByWorktreePath: [String: UUID],
    reviewSummaryDraftsByWorktreePath: [String: WorkspaceReviewSummaryDraft] = [:]
  ) {
    self.target = target
    self.terminalTabsByWorktreePath = terminalTabsByWorktreePath
    self.selectedTerminalTabIDsByWorktreePath = selectedTerminalTabIDsByWorktreePath
    self.reviewSummaryDraftsByWorktreePath = reviewSummaryDraftsByWorktreePath
  }

  private enum CodingKeys: String, CodingKey {
    case target
    case terminalTabsByWorktreePath
    case selectedTerminalTabIDsByWorktreePath
    case reviewSummaryDraftsByWorktreePath
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    target = try container.decode(WorkspaceTarget.self, forKey: .target)
    terminalTabsByWorktreePath = try container.decode(
      [String: [PersistedWorkspaceTerminalTab]].self,
      forKey: .terminalTabsByWorktreePath
    )
    selectedTerminalTabIDsByWorktreePath = try container.decode(
      [String: UUID].self,
      forKey: .selectedTerminalTabIDsByWorktreePath
    )
    reviewSummaryDraftsByWorktreePath =
      try container.decodeIfPresent(
        [String: WorkspaceReviewSummaryDraft].self,
        forKey: .reviewSummaryDraftsByWorktreePath
      ) ?? [:]
  }
}

enum PersistedWorkspaceTerminalTabKind: Codable, Equatable {
  case shell
  case agent(profileName: String, icon: String)

  private enum CodingKeys: String, CodingKey {
    case discriminator
    case profileName
    case icon
  }

  private enum Discriminator: String, Codable {
    case shell
    case agent
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Discriminator.self, forKey: .discriminator) {
    case .shell:
      self = .shell
    case .agent:
      self = .agent(
        profileName: try container.decode(String.self, forKey: .profileName),
        icon: try container.decode(String.self, forKey: .icon)
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .shell:
      try container.encode(Discriminator.shell, forKey: .discriminator)
    case .agent(let profileName, let icon):
      try container.encode(Discriminator.agent, forKey: .discriminator)
      try container.encode(profileName, forKey: .profileName)
      try container.encode(icon, forKey: .icon)
    }
  }
}

struct PersistedWorkspaceTerminalTab: Codable, Equatable {
  let id: UUID
  let profileID: String?
  let worktreePath: String
  let worktreeLabel: String
  let title: String
  let commandDescription: String
  let baseCommandDescription: String
  let kind: PersistedWorkspaceTerminalTabKind
  let agentFamilyID: AgentFamilyID?
  let createdAt: Date
  let isSandboxed: Bool
  let yoloMode: Bool
  let writableRoots: [String]
  let resumeArgumentTemplate: String
  let keepsRunningAfterQuit: Bool
  let terminalSession: TerminalSessionReference?
  let resumeSessionID: String?
  let resumeCommandDescription: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case profileID
    case worktreePath
    case worktreeLabel
    case title
    case commandDescription
    case baseCommandDescription
    case kind
    case agentFamilyID
    case createdAt
    case isSandboxed
    case yoloMode
    case writableRoots
    case resumeArgumentTemplate
    case keepsRunningAfterQuit
    case terminalSession
    case resumeSessionID
    case resumeCommandDescription
  }

  init(
    id: UUID,
    profileID: String? = nil,
    worktreePath: String,
    worktreeLabel: String,
    title: String,
    commandDescription: String,
    baseCommandDescription: String? = nil,
    kind: PersistedWorkspaceTerminalTabKind,
    agentFamilyID: AgentFamilyID? = nil,
    createdAt: Date,
    isSandboxed: Bool,
    yoloMode: Bool = false,
    writableRoots: [String],
    resumeArgumentTemplate: String = "",
    keepsRunningAfterQuit: Bool = false,
    terminalSession: TerminalSessionReference? = nil,
    resumeSessionID: String? = nil,
    resumeCommandDescription: String? = nil
  ) {
    self.id = id
    self.profileID = profileID
    self.worktreePath = worktreePath
    self.worktreeLabel = worktreeLabel
    self.title = title
    self.commandDescription = commandDescription
    self.baseCommandDescription = baseCommandDescription ?? commandDescription
    self.kind = kind
    self.agentFamilyID = agentFamilyID
    self.createdAt = createdAt
    self.isSandboxed = isSandboxed
    self.yoloMode = yoloMode
    self.writableRoots = writableRoots
    self.resumeArgumentTemplate = resumeArgumentTemplate
    self.keepsRunningAfterQuit = keepsRunningAfterQuit
    self.terminalSession = terminalSession
    self.resumeSessionID = resumeSessionID
    self.resumeCommandDescription = resumeCommandDescription
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
    worktreePath = try container.decode(String.self, forKey: .worktreePath)
    worktreeLabel = try container.decode(String.self, forKey: .worktreeLabel)
    title = try container.decode(String.self, forKey: .title)
    commandDescription = try container.decode(String.self, forKey: .commandDescription)
    baseCommandDescription =
      try container.decodeIfPresent(String.self, forKey: .baseCommandDescription)
      ?? commandDescription
    kind = try container.decode(PersistedWorkspaceTerminalTabKind.self, forKey: .kind)
    agentFamilyID = try container.decodeIfPresent(AgentFamilyID.self, forKey: .agentFamilyID)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    isSandboxed = try container.decode(Bool.self, forKey: .isSandboxed)
    yoloMode = try container.decodeIfPresent(Bool.self, forKey: .yoloMode) ?? false
    writableRoots = try container.decode([String].self, forKey: .writableRoots)
    resumeArgumentTemplate =
      try container.decodeIfPresent(String.self, forKey: .resumeArgumentTemplate) ?? ""
    keepsRunningAfterQuit =
      try container.decodeIfPresent(Bool.self, forKey: .keepsRunningAfterQuit) ?? false
    terminalSession = try container.decodeIfPresent(
      TerminalSessionReference.self,
      forKey: .terminalSession
    )
    resumeSessionID = try container.decodeIfPresent(String.self, forKey: .resumeSessionID)
    resumeCommandDescription = try container.decodeIfPresent(
      String.self,
      forKey: .resumeCommandDescription
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(profileID, forKey: .profileID)
    try container.encode(worktreePath, forKey: .worktreePath)
    try container.encode(worktreeLabel, forKey: .worktreeLabel)
    try container.encode(title, forKey: .title)
    try container.encode(commandDescription, forKey: .commandDescription)
    try container.encode(baseCommandDescription, forKey: .baseCommandDescription)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(agentFamilyID, forKey: .agentFamilyID)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(isSandboxed, forKey: .isSandboxed)
    try container.encode(yoloMode, forKey: .yoloMode)
    try container.encode(writableRoots, forKey: .writableRoots)
    // Resume templates are derived from the saved agent profile/command at restore time.
    // Avoid persisting template strings into each tab snapshot.
    try container.encode(keepsRunningAfterQuit, forKey: .keepsRunningAfterQuit)
    try container.encodeIfPresent(terminalSession, forKey: .terminalSession)
    try container.encodeIfPresent(resumeSessionID, forKey: .resumeSessionID)
    try container.encodeIfPresent(resumeCommandDescription, forKey: .resumeCommandDescription)
  }
}
