import Foundation

enum WorktreeMergeStrategy: String, CaseIterable, Identifiable, Sendable {
  case mergeCommit
  case rebaseAndMerge
  case squashAndMerge

  var id: String { rawValue }

  var buttonTitle: String {
    switch self {
    case .mergeCommit:
      "Merge Back"
    case .rebaseAndMerge:
      "Rebase and Merge Back"
    case .squashAndMerge:
      "Squash and Merge Back"
    }
  }

  var toolbarTitle: String {
    switch self {
    case .mergeCommit:
      "Merge"
    case .rebaseAndMerge:
      "Rebase"
    case .squashAndMerge:
      "Squash"
    }
  }

  var menuTitle: String {
    switch self {
    case .mergeCommit:
      "Create merge commit"
    case .rebaseAndMerge:
      "Rebase and merge"
    case .squashAndMerge:
      "Squash and merge"
    }
  }

  var finalizeMenuTitle: String {
    switch self {
    case .mergeCommit:
      "Merge back with merge commit"
    case .rebaseAndMerge:
      "Rebase and merge back"
    case .squashAndMerge:
      "Squash and merge back"
    }
  }

  var finalizeAction: WorktreeFinalizeAction {
    switch self {
    case .mergeCommit:
      .mergeCommitToBase
    case .rebaseAndMerge:
      .rebaseAndMergeToBase
    case .squashAndMerge:
      .squashAndMergeToBase
    }
  }
}

enum WorktreeMergeStrategySettings {
  static let defaultStrategyStorageKey = "defaultWorktreeMergeStrategy"
  private static let projectStrategiesStorageKey = "worktreeMergeStrategiesByRepoRoot"

  static func defaultStrategy(userDefaults: UserDefaults = .standard) -> WorktreeMergeStrategy {
    let rawValue = userDefaults.string(forKey: defaultStrategyStorageKey)
    return WorktreeMergeStrategy(rawValue: rawValue ?? "") ?? .mergeCommit
  }

  static func strategy(
    for repoRoot: String,
    userDefaults: UserDefaults = .standard
  ) -> WorktreeMergeStrategy {
    let normalizedRepoRoot = normalizedPath(repoRoot)
    let projectStrategies = loadProjectStrategies(userDefaults: userDefaults)
    if let rawValue = projectStrategies[normalizedRepoRoot],
      let strategy = WorktreeMergeStrategy(rawValue: rawValue)
    {
      return strategy
    }

    return defaultStrategy(userDefaults: userDefaults)
  }

  static func setStrategy(
    _ strategy: WorktreeMergeStrategy,
    for repoRoot: String,
    userDefaults: UserDefaults = .standard
  ) {
    var projectStrategies = loadProjectStrategies(userDefaults: userDefaults)
    projectStrategies[normalizedPath(repoRoot)] = strategy.rawValue
    saveProjectStrategies(projectStrategies, userDefaults: userDefaults)
  }

  private static func loadProjectStrategies(userDefaults: UserDefaults) -> [String: String] {
    guard let data = userDefaults.data(forKey: projectStrategiesStorageKey),
      let projectStrategies = try? JSONDecoder().decode([String: String].self, from: data)
    else {
      return [:]
    }

    return projectStrategies
  }

  private static func saveProjectStrategies(
    _ projectStrategies: [String: String],
    userDefaults: UserDefaults
  ) {
    guard let data = try? JSONEncoder().encode(projectStrategies) else { return }
    userDefaults.set(data, forKey: projectStrategiesStorageKey)
  }

  private static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
