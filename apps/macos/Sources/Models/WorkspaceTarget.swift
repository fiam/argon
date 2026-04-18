import Foundation

struct WorkspaceTarget: Codable, Hashable, Sendable {
  let repoRoot: String
  let repoCommonDir: String
  let selectedWorktreePath: String?

  func updatingSelectedWorktreePath(_ selectedWorktreePath: String?) -> WorkspaceTarget {
    WorkspaceTarget(
      repoRoot: repoRoot,
      repoCommonDir: repoCommonDir,
      selectedWorktreePath: selectedWorktreePath
    )
  }

  func restoringSelectedWorktreePath(_ restoredSelectedWorktreePath: String?) -> WorkspaceTarget {
    guard let restoredSelectedWorktreePath else { return self }
    return updatingSelectedWorktreePath(restoredSelectedWorktreePath)
  }
}
