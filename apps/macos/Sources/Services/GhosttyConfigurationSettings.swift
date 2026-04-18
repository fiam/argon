import Foundation
import GhosttyKit

enum GhosttyConfigurationSettings {
  static let storageKey = "ghosttyConfigurationText"
  static let docsURL = URL(string: "https://ghostty.org/docs/config/reference")!

  static func resolvedConfigPath() -> String? {
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

  static func resolvedConfigText() -> String? {
    guard let path = resolvedConfigPath() else { return nil }
    return try? String(contentsOfFile: path, encoding: .utf8)
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
