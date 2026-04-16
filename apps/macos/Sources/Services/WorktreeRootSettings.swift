import Foundation

enum WorktreeRootSettings {
  static let storageKey = "worktreeRootPath"

  static func defaultRootPath(fileManager: FileManager = .default) -> String {
    let appSupportURL =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)

    return
      appSupportURL
      .appendingPathComponent("Argon", isDirectory: true)
      .appendingPathComponent("Worktrees", isDirectory: true)
      .standardizedFileURL
      .path
  }

  static func configuredRootPath(
    userDefaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) -> String {
    let storedPath =
      userDefaults.string(forKey: storageKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !storedPath.isEmpty else {
      return defaultRootPath(fileManager: fileManager)
    }

    return normalizedUserPath(storedPath, fileManager: fileManager)
  }

  static func suggestedPath(rootPath: String, repoRoot: String, worktreeName: String) -> String {
    let baseURL = URL(fileURLWithPath: normalizedUserPath(rootPath), isDirectory: true)
      .standardizedFileURL
    let repoComponents = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
      .split(separator: "/")
      .map(String.init)
    let repoURL = repoComponents.reduce(baseURL) { partialURL, component in
      partialURL.appendingPathComponent(component, isDirectory: true)
    }

    return repoURL.appendingPathComponent(worktreeName, isDirectory: true).path
  }

  static func abbreviatedPath(_ path: String) -> String {
    NSString(string: normalizedUserPath(path)).abbreviatingWithTildeInPath
  }

  private static func normalizedUserPath(
    _ path: String,
    fileManager: FileManager = .default
  ) -> String {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else {
      return defaultRootPath(fileManager: fileManager)
    }

    let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
    let absolutePath =
      if expandedPath.hasPrefix("/") {
        expandedPath
      } else {
        fileManager.homeDirectoryForCurrentUser
          .appendingPathComponent(expandedPath, isDirectory: true)
          .path
      }

    return URL(fileURLWithPath: absolutePath).standardizedFileURL.path
  }
}
