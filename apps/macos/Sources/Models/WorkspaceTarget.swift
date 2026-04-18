import Foundation

struct WorkspaceTarget: Codable, Hashable, Sendable {
  let repoRoot: String
  let repoCommonDir: String
  let selectedWorktreePath: String?
  let showsLinkedWorktreeWarning: Bool

  init(
    repoRoot: String,
    repoCommonDir: String,
    selectedWorktreePath: String?,
    showsLinkedWorktreeWarning: Bool = false
  ) {
    self.repoRoot = repoRoot
    self.repoCommonDir = repoCommonDir
    self.selectedWorktreePath = selectedWorktreePath
    self.showsLinkedWorktreeWarning = showsLinkedWorktreeWarning
  }

  private enum CodingKeys: String, CodingKey {
    case repoRoot
    case repoCommonDir
    case selectedWorktreePath
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    repoRoot = try container.decode(String.self, forKey: .repoRoot)
    repoCommonDir = try container.decode(String.self, forKey: .repoCommonDir)
    selectedWorktreePath = try container.decodeIfPresent(String.self, forKey: .selectedWorktreePath)
    showsLinkedWorktreeWarning = false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(repoRoot, forKey: .repoRoot)
    try container.encode(repoCommonDir, forKey: .repoCommonDir)
    try container.encodeIfPresent(selectedWorktreePath, forKey: .selectedWorktreePath)
  }

  func updatingSelectedWorktreePath(_ selectedWorktreePath: String?) -> WorkspaceTarget {
    WorkspaceTarget(
      repoRoot: repoRoot,
      repoCommonDir: repoCommonDir,
      selectedWorktreePath: selectedWorktreePath,
      showsLinkedWorktreeWarning: showsLinkedWorktreeWarning
    )
  }

  func restoringSelectedWorktreePath(_ restoredSelectedWorktreePath: String?) -> WorkspaceTarget {
    guard let restoredSelectedWorktreePath else { return self }
    return updatingSelectedWorktreePath(restoredSelectedWorktreePath)
  }
}
