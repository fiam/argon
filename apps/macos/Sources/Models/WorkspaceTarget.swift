import Foundation

struct WorkspaceTarget: Codable, Hashable, Sendable {
  let repoRoot: String
  let repoCommonDir: String
  let selectedWorktreePath: String?
}
