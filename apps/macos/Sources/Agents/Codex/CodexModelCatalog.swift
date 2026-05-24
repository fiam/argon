import Foundation

enum CodexModelCatalog {
  private static let timeout: TimeInterval = 8

  static func loadChoices(command: String) async -> [AgentHarnessParameterChoice] {
    await Task.detached(priority: .utility) {
      let executable = commandExecutableToken(from: command)
      guard URL(fileURLWithPath: executable).lastPathComponent.lowercased() == "codex" else {
        return []
      }

      let probeCommand = "\(shellQuote(executable)) debug models"
      guard let output = UserShell.commandOutput(probeCommand, timeout: timeout),
        output.succeeded
      else { return [] }

      return parseChoices(from: output.stdout)
    }.value
  }

  static func parseChoices(from json: String) -> [AgentHarnessParameterChoice] {
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any],
      let models = dictionary["models"] as? [[String: Any]]
    else { return [] }

    return models.compactMap { model in
      guard
        let slug = trimmedString(model["slug"]),
        isListVisible(model)
      else { return nil }

      return AgentHarnessParameterChoice(
        value: slug,
        label: trimmedString(model["display_name"]) ?? slug
      )
    }
  }

  private static func isListVisible(_ model: [String: Any]) -> Bool {
    guard let visibility = trimmedString(model["visibility"]) else { return true }
    return visibility == "list"
  }

  private static func trimmedString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
