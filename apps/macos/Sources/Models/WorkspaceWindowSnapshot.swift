import Foundation

struct PersistedWorkspaceWindowSnapshot: Codable, Equatable {
  let target: WorkspaceTarget
  let terminalTabsByWorktreePath: [String: [PersistedWorkspaceTerminalTab]]
  let selectedTerminalTabIDsByWorktreePath: [String: UUID]
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
}
