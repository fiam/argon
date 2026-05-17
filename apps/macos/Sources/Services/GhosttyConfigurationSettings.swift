import Foundation
import GhosttyKit

enum GhosttyConfigurationSettings {
  static let storageKey = "ghosttyConfigurationText"
  static let docsURL = URL(string: "https://ghostty.org/docs/config/reference")!
  static let highlightPath = "ghostty.ini"

  static func resolvedConfigPath() -> String? {
    resolvedConfigPath(
      fileManager: .default,
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      ghosttyOpenPath: ghosttyResolvedConfigOpenPath()
    )
  }

  static func resolvedConfigPath(
    fileManager: FileManager,
    environment: [String: String],
    homeDirectory: URL,
    ghosttyOpenPath: String?
  ) -> String? {
    guard let ghosttyOpenPath else {
      return preferredExistingXDGConfigPath(
        fileManager: fileManager,
        environment: environment,
        homeDirectory: homeDirectory
      )
    }

    guard
      let xdgPath = preferredExistingXDGConfigPath(
        fileManager: fileManager,
        environment: environment,
        homeDirectory: homeDirectory
      )
    else {
      return ghosttyOpenPath
    }

    if isGeneratedTemplateOnly(atPath: ghosttyOpenPath, fileManager: fileManager) {
      return xdgPath
    }

    return ghosttyOpenPath
  }

  static func resolvedConfigText() -> String? {
    resolvedConfigText(
      fileManager: .default,
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      ghosttyOpenPath: ghosttyResolvedConfigOpenPath()
    )
  }

  static func resolvedConfigText(
    fileManager: FileManager,
    environment: [String: String],
    homeDirectory: URL,
    ghosttyOpenPath: String?
  ) -> String? {
    guard
      let path = resolvedConfigPath(
        fileManager: fileManager,
        environment: environment,
        homeDirectory: homeDirectory,
        ghosttyOpenPath: ghosttyOpenPath
      )
    else {
      return nil
    }
    return try? String(contentsOfFile: path, encoding: .utf8)
  }

  private static func ghosttyResolvedConfigOpenPath() -> String? {
    do {
      try GhosttyRuntime.ensureInitialized()
    } catch {
      return nil
    }

    let value = ghostty_config_open_path()
    defer { ghostty_string_free(value) }

    guard let pointer = value.ptr, value.len > 0 else { return nil }
    let data = Data(bytes: pointer, count: Int(value.len))
    guard let path = String(data: data, encoding: .utf8) else { return nil }
    return path.isEmpty ? nil : path
  }

  private static func preferredExistingXDGConfigPath(
    fileManager: FileManager,
    environment: [String: String],
    homeDirectory: URL
  ) -> String? {
    let ghosttyDirectory = xdgConfigHome(environment: environment, homeDirectory: homeDirectory)
      .appendingPathComponent("ghostty", isDirectory: true)
    let defaultPath = ghosttyDirectory.appendingPathComponent("config.ghostty").path
    if isReadableNonEmptyFile(atPath: defaultPath, fileManager: fileManager) {
      return defaultPath
    }

    let legacyPath = ghosttyDirectory.appendingPathComponent("config").path
    if isReadableNonEmptyFile(atPath: legacyPath, fileManager: fileManager) {
      return legacyPath
    }

    return nil
  }

  private static func xdgConfigHome(environment: [String: String], homeDirectory: URL) -> URL {
    if let configuredPath = environment["XDG_CONFIG_HOME"],
      !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let expandedPath = (configuredPath as NSString).expandingTildeInPath
      if expandedPath.hasPrefix("/") {
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
      }

      return homeDirectory.appendingPathComponent(expandedPath, isDirectory: true)
    }

    return homeDirectory.appendingPathComponent(".config", isDirectory: true)
  }

  private static func isReadableNonEmptyFile(atPath path: String, fileManager: FileManager) -> Bool
  {
    guard let data = fileManager.contents(atPath: path), !data.isEmpty else { return false }

    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
    else {
      return false
    }

    return true
  }

  private static func isGeneratedTemplateOnly(atPath path: String, fileManager: FileManager) -> Bool
  {
    guard let data = fileManager.contents(atPath: path), !data.isEmpty else { return false }
    guard let text = String(data: data, encoding: .utf8) else { return false }
    guard text.contains("template file has been automatically created") else { return false }
    guard text.contains("Ghostty couldn't find any existing config files") else { return false }

    return !containsActiveConfigEntry(text)
  }

  private static func containsActiveConfigEntry(_ configText: String) -> Bool {
    configText.components(separatedBy: .newlines).contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmed.isEmpty && !trimmed.hasPrefix("#") && trimmed.contains("=")
    }
  }

  static func fontSize(from configText: String) -> Double? {
    for line in configText.components(separatedBy: .newlines).reversed() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      guard let separatorIndex = trimmed.firstIndex(of: "=") else { continue }

      let key = String(trimmed[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard key == "font-size" else { continue }

      let valuePortion = String(trimmed[trimmed.index(after: separatorIndex)...])
      let cleanValue =
        valuePortion
        .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

      if let parsed = Double(cleanValue), parsed > 0 {
        return parsed
      }
    }

    return nil
  }
}
