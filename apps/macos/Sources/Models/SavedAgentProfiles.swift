import Foundation

struct SavedAgentProfile: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var command: String
  var icon: String
  /// Flags appended to the command to enable auto-approve mode.
  /// Empty string means the agent doesn't support a yolo mode.
  var yoloFlag: String
  /// Optional command-line template used to pass a quoted prompt.
  /// Use `{{prompt}}` where the shell-quoted prompt should be inserted.
  /// Leave empty to append the quoted prompt as a trailing argument.
  var promptArgumentTemplate: String
  /// Optional command-line arguments used to resume an existing session.
  /// Use `{{session_id}}` where the shell-quoted session ID should be inserted.
  /// Leave empty to disable session-resume restoration for this profile.
  var resumeArgumentTemplate: String

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case command
    case icon
    case yoloFlag
    case promptArgumentTemplate
    case resumeArgumentTemplate
  }

  init(
    id: String,
    name: String,
    command: String,
    icon: String,
    yoloFlag: String,
    promptArgumentTemplate: String = "",
    resumeArgumentTemplate: String = ""
  ) {
    self.id = id
    self.name = name
    self.command = command
    self.icon = icon
    self.yoloFlag = yoloFlag
    self.promptArgumentTemplate = promptArgumentTemplate
    self.resumeArgumentTemplate = resumeArgumentTemplate
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    command = try container.decode(String.self, forKey: .command)
    icon = try container.decode(String.self, forKey: .icon)
    yoloFlag = try container.decode(String.self, forKey: .yoloFlag)
    promptArgumentTemplate =
      try container.decodeIfPresent(String.self, forKey: .promptArgumentTemplate) ?? ""
    resumeArgumentTemplate =
      try container.decodeIfPresent(String.self, forKey: .resumeArgumentTemplate) ?? ""
  }

  /// Build the full command, optionally with yolo flags.
  func fullCommand(yolo: Bool, sandboxed: Bool = false, prompt: String? = nil) -> String {
    var components = [command]
    if yolo && !yoloFlag.isEmpty {
      components.append(yoloFlag)
    }
    return renderAgentCommand(
      baseCommand: components.joined(separator: " "),
      promptArgumentTemplate: promptArgumentTemplate,
      prompt: prompt
    )
  }

  /// Convert to the AgentProfile used by the launch sheet.
  func toAgentProfile(isDetected: Bool) -> AgentProfile {
    AgentProfile(
      id: id,
      name: name,
      command: command,
      icon: icon,
      isDetected: isDetected,
      promptArgumentTemplate: promptArgumentTemplate
    )
  }

  var baseCommand: String {
    commandExecutableName(from: command)
  }

  func renderedResumeCommand(baseCommand: String, sessionID: String?) -> String? {
    renderAgentResumeCommand(
      baseCommand: baseCommand,
      resumeArgumentTemplate: resumeArgumentTemplate,
      sessionID: sessionID
    )
  }
}

@MainActor
@Observable
final class SavedAgentProfiles {
  private static let key = "savedAgentProfiles"
  nonisolated private static let legacyBuiltinResumeTemplatesByID: [String: String] = [
    "claude-code": "-c",
    "codex": "resume {{session_id}}",
    "gemini": "--resume latest",
  ]

  var profiles: [SavedAgentProfile] = []

  /// Well-known defaults shipped with the app.
  static let builtinDefaults: [SavedAgentProfile] = [
    SavedAgentProfile(
      id: "claude-code", name: "Claude Code",
      command: "claude", icon: "claude",
      yoloFlag: "--dangerously-skip-permissions",
      resumeArgumentTemplate: "-c"),
    SavedAgentProfile(
      id: "codex", name: "Codex",
      command: "codex", icon: "codex",
      yoloFlag: "--yolo",
      resumeArgumentTemplate: "resume {{session_id}}"),
    SavedAgentProfile(
      id: "gemini", name: "Gemini CLI",
      command: "gemini", icon: "gemini",
      yoloFlag: "-y",
      resumeArgumentTemplate: "--resume latest"),
  ]

  init() {
    load()
    if profiles.isEmpty {
      profiles = Self.builtinDefaults
      save()
    }
  }

  func add(_ profile: SavedAgentProfile) {
    profiles.append(profile)
    save()
  }

  func update(_ profile: SavedAgentProfile) {
    if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[idx] = profile
      save()
    }
  }

  func remove(at offsets: IndexSet) {
    profiles.remove(atOffsets: offsets)
    save()
  }

  func remove(id: String) {
    profiles.removeAll { $0.id == id }
    save()
  }

  func move(from source: IndexSet, to destination: Int) {
    profiles.move(fromOffsets: source, toOffset: destination)
    save()
  }

  func resetToDefaults() {
    profiles = Self.builtinDefaults
    save()
  }
  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Self.key),
      let decoded = try? JSONDecoder().decode([SavedAgentProfile].self, from: data)
    else { return }
    let migrated = Self.applyingLegacyResumeDefaults(
      to: decoded,
      missingResumeFieldProfileIDs: Self.missingResumeFieldProfileIDs(from: data) ?? []
    )
    profiles = migrated
    if migrated != decoded {
      save()
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(profiles) {
      UserDefaults.standard.set(data, forKey: Self.key)
    }
  }

  nonisolated static func applyingLegacyResumeDefaults(
    to decodedProfiles: [SavedAgentProfile],
    missingResumeFieldProfileIDs: Set<String>
  ) -> [SavedAgentProfile] {
    guard !missingResumeFieldProfileIDs.isEmpty else { return decodedProfiles }

    var migrated = decodedProfiles
    for index in migrated.indices {
      let id = migrated[index].id
      guard missingResumeFieldProfileIDs.contains(id) else { continue }
      guard migrated[index].resumeArgumentTemplate.isEmpty else { continue }
      guard
        let template = legacyBuiltinResumeTemplatesByID[id],
        !template.isEmpty
      else { continue }
      migrated[index].resumeArgumentTemplate = template
    }
    return migrated
  }

  nonisolated static func missingResumeFieldProfileIDs(from encodedProfiles: Data) -> Set<String>? {
    guard
      let json = try? JSONSerialization.jsonObject(with: encodedProfiles) as? [[String: Any]]
    else { return nil }

    var ids = Set<String>()
    for profile in json {
      guard let id = profile["id"] as? String else { continue }
      guard profile["resumeArgumentTemplate"] == nil else { continue }
      ids.insert(id)
    }
    return ids
  }
}

func renderAgentCommand(
  baseCommand: String,
  promptArgumentTemplate: String,
  prompt: String?
) -> String {
  guard let prompt, !prompt.isEmpty else { return baseCommand }

  let trimmedTemplate = promptArgumentTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
  let quotedPrompt = shellQuote(prompt)

  guard !trimmedTemplate.isEmpty else {
    return "\(baseCommand) \(quotedPrompt)"
  }

  let renderedTemplate = trimmedTemplate.replacingOccurrences(of: "{{prompt}}", with: quotedPrompt)
  if trimmedTemplate.contains("{{prompt}}") {
    return "\(baseCommand) \(renderedTemplate)"
  }

  return "\(baseCommand) \(renderedTemplate) \(quotedPrompt)"
}

func renderAgentResumeCommand(
  baseCommand: String,
  resumeArgumentTemplate: String,
  sessionID: String?
) -> String? {
  let trimmedTemplate = resumeArgumentTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedTemplate.isEmpty else { return nil }

  let renderedTemplate: String
  if trimmedTemplate.contains("{{session_id}}") {
    guard let sessionID, !sessionID.isEmpty else { return nil }
    renderedTemplate = trimmedTemplate.replacingOccurrences(
      of: "{{session_id}}",
      with: shellQuote(sessionID)
    )
  } else {
    renderedTemplate = trimmedTemplate
  }

  return "\(baseCommand) \(renderedTemplate)"
}

private func shellQuote(_ value: String) -> String {
  let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
  return "'\(escaped)'"
}

func commandExecutableName(from command: String) -> String {
  let executable = commandExecutableToken(from: command)
  let basename = URL(fileURLWithPath: executable).lastPathComponent
  return basename.isEmpty ? "agent" : basename
}

func commandExecutableToken(from command: String) -> String {
  let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return "agent" }

  var token = ""
  var index = trimmed.startIndex
  var quote: Character?

  while index < trimmed.endIndex {
    let character = trimmed[index]

    if let activeQuote = quote {
      if character == activeQuote {
        quote = nil
        index = trimmed.index(after: index)
        continue
      }

      if activeQuote == "\"" && character == "\\" {
        let nextIndex = trimmed.index(after: index)
        if nextIndex < trimmed.endIndex {
          token.append(trimmed[nextIndex])
          index = trimmed.index(after: nextIndex)
          continue
        }
      }

      token.append(character)
      index = trimmed.index(after: index)
      continue
    }

    if character.isWhitespace {
      if token.isEmpty {
        index = trimmed.index(after: index)
        continue
      }
      break
    }

    if character == "'" || character == "\"" {
      quote = character
      index = trimmed.index(after: index)
      continue
    }

    if character == "\\" {
      let nextIndex = trimmed.index(after: index)
      if nextIndex < trimmed.endIndex {
        token.append(trimmed[nextIndex])
        index = trimmed.index(after: nextIndex)
        continue
      }
    }

    token.append(character)
    index = trimmed.index(after: index)
  }

  return token.isEmpty ? trimmed : token
}
