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
  let worktreePath: String
  let worktreeLabel: String
  let title: String
  let commandDescription: String
  let kind: PersistedWorkspaceTerminalTabKind
  let createdAt: Date
  let isSandboxed: Bool
  let writableRoots: [String]
  let resumeArgumentTemplate: String
  let resumeSessionID: String?
  let resumeCommandDescription: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case worktreePath
    case worktreeLabel
    case title
    case commandDescription
    case kind
    case createdAt
    case isSandboxed
    case writableRoots
    case resumeArgumentTemplate
    case resumeSessionID
    case resumeCommandDescription
  }

  init(
    id: UUID,
    worktreePath: String,
    worktreeLabel: String,
    title: String,
    commandDescription: String,
    kind: PersistedWorkspaceTerminalTabKind,
    createdAt: Date,
    isSandboxed: Bool,
    writableRoots: [String],
    resumeArgumentTemplate: String = "",
    resumeSessionID: String? = nil,
    resumeCommandDescription: String? = nil
  ) {
    self.id = id
    self.worktreePath = worktreePath
    self.worktreeLabel = worktreeLabel
    self.title = title
    self.commandDescription = commandDescription
    self.kind = kind
    self.createdAt = createdAt
    self.isSandboxed = isSandboxed
    self.writableRoots = writableRoots
    self.resumeArgumentTemplate = resumeArgumentTemplate
    self.resumeSessionID = resumeSessionID
    self.resumeCommandDescription = resumeCommandDescription
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    worktreePath = try container.decode(String.self, forKey: .worktreePath)
    worktreeLabel = try container.decode(String.self, forKey: .worktreeLabel)
    title = try container.decode(String.self, forKey: .title)
    commandDescription = try container.decode(String.self, forKey: .commandDescription)
    kind = try container.decode(PersistedWorkspaceTerminalTabKind.self, forKey: .kind)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    isSandboxed = try container.decode(Bool.self, forKey: .isSandboxed)
    writableRoots = try container.decode([String].self, forKey: .writableRoots)
    resumeArgumentTemplate =
      try container.decodeIfPresent(String.self, forKey: .resumeArgumentTemplate) ?? ""
    resumeSessionID = try container.decodeIfPresent(String.self, forKey: .resumeSessionID)
    resumeCommandDescription = try container.decodeIfPresent(
      String.self,
      forKey: .resumeCommandDescription
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(worktreePath, forKey: .worktreePath)
    try container.encode(worktreeLabel, forKey: .worktreeLabel)
    try container.encode(title, forKey: .title)
    try container.encode(commandDescription, forKey: .commandDescription)
    try container.encode(kind, forKey: .kind)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(isSandboxed, forKey: .isSandboxed)
    try container.encode(writableRoots, forKey: .writableRoots)
    // Resume templates are derived from the saved agent profile/command at restore time.
    // Avoid persisting template strings into each tab snapshot.
    try container.encodeIfPresent(resumeSessionID, forKey: .resumeSessionID)
    try container.encodeIfPresent(resumeCommandDescription, forKey: .resumeCommandDescription)
  }
}
