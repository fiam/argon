import Foundation

enum AgentFamilyID: String, Codable, CaseIterable, Sendable {
  case claudeCode = "claude-code"
  case codex
  case gemini

  var defaultProfileID: String {
    rawValue
  }
}

struct AgentHarnessDefinition: Sendable {
  let familyID: AgentFamilyID
  let name: String
  let command: String
  let icon: String
  let yoloFlag: String
  let promptArgumentTemplate: String
  let resumeArgumentTemplate: String
  let versionArguments: [String]

  var defaultProfile: SavedAgentProfile {
    SavedAgentProfile(
      id: familyID.defaultProfileID,
      familyID: familyID,
      name: name,
      command: command,
      icon: icon,
      yoloFlag: yoloFlag,
      promptArgumentTemplate: promptArgumentTemplate,
      resumeArgumentTemplate: resumeArgumentTemplate
    )
  }
}

enum AgentHarnesses {
  private static let definitionsByFamily: [AgentFamilyID: AgentHarnessDefinition] = [
    .claudeCode: AgentHarnessDefinition(
      familyID: .claudeCode,
      name: "Claude Code",
      command: "claude",
      icon: "claude",
      yoloFlag: "--dangerously-skip-permissions",
      promptArgumentTemplate: "",
      resumeArgumentTemplate: "-c",
      versionArguments: ["--version"]
    ),
    .codex: AgentHarnessDefinition(
      familyID: .codex,
      name: "Codex",
      command: "codex",
      icon: "codex",
      yoloFlag: "--full-auto",
      promptArgumentTemplate: "",
      resumeArgumentTemplate: "resume {{session_id}}",
      versionArguments: ["--version"]
    ),
    .gemini: AgentHarnessDefinition(
      familyID: .gemini,
      name: "Gemini CLI",
      command: "gemini",
      icon: "gemini",
      yoloFlag: "-y",
      promptArgumentTemplate: "",
      resumeArgumentTemplate: "--resume latest",
      versionArguments: ["--version"]
    ),
  ]

  static func definition(for familyID: AgentFamilyID) -> AgentHarnessDefinition {
    definitionsByFamily[familyID]!
  }

  static func displayVersion(for familyID: AgentFamilyID, rawOutput: String?) -> String? {
    guard let rawOutput else { return nil }
    let firstLine = rawOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? rawOutput
    let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    switch familyID {
    case .claudeCode:
      return trimmed.replacingOccurrences(of: " (Claude Code)", with: "")
    case .codex:
      return trimmed.replacingOccurrences(of: "codex-cli ", with: "")
    case .gemini:
      return trimmed
    }
  }
}

struct SavedAgentProfile: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var familyID: AgentFamilyID?
  var name: String
  var command: String
  var icon: String
  var isEnabled: Bool
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

  init(
    id: String,
    familyID: AgentFamilyID? = nil,
    name: String,
    command: String,
    icon: String,
    isEnabled: Bool = true,
    yoloFlag: String,
    promptArgumentTemplate: String = "",
    resumeArgumentTemplate: String = ""
  ) {
    self.id = id
    self.familyID = familyID
    self.name = name
    self.command = command
    self.icon = icon
    self.isEnabled = isEnabled
    self.yoloFlag = yoloFlag
    self.promptArgumentTemplate = promptArgumentTemplate
    self.resumeArgumentTemplate = resumeArgumentTemplate
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case familyID
    case name
    case command
    case icon
    case isEnabled
    case yoloFlag
    case promptArgumentTemplate
    case resumeArgumentTemplate
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.familyID = try container.decodeIfPresent(AgentFamilyID.self, forKey: .familyID)
    self.name = try container.decode(String.self, forKey: .name)
    self.command = try container.decode(String.self, forKey: .command)
    self.icon = try container.decode(String.self, forKey: .icon)
    self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    self.yoloFlag = try container.decode(String.self, forKey: .yoloFlag)
    self.promptArgumentTemplate = try container.decode(
      String.self,
      forKey: .promptArgumentTemplate
    )
    self.resumeArgumentTemplate = try container.decode(
      String.self,
      forKey: .resumeArgumentTemplate
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(familyID, forKey: .familyID)
    try container.encode(name, forKey: .name)
    try container.encode(command, forKey: .command)
    try container.encode(icon, forKey: .icon)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(yoloFlag, forKey: .yoloFlag)
    try container.encode(promptArgumentTemplate, forKey: .promptArgumentTemplate)
    try container.encode(resumeArgumentTemplate, forKey: .resumeArgumentTemplate)
  }

  var isBuiltIn: Bool {
    familyID != nil
  }

  var availabilityCommand: String {
    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else { return "" }
    return commandExecutableToken(from: trimmedCommand)
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

extension AgentFamilyID {
  var defaultProfile: SavedAgentProfile {
    AgentHarnesses.definition(for: self).defaultProfile
  }

  var harness: AgentHarnessDefinition {
    AgentHarnesses.definition(for: self)
  }

  static func inferred(from profile: SavedAgentProfile) -> AgentFamilyID? {
    allCases.first { family in
      family.defaultProfileID == profile.id
    }
  }
}

@MainActor
@Observable
final class SavedAgentProfiles {
  private static let key = "savedAgentProfiles"
  private let userDefaults: UserDefaults
  private let storageKey: String

  var profiles: [SavedAgentProfile] = []

  var enabledProfiles: [SavedAgentProfile] {
    profiles.filter(\.isEnabled)
  }

  /// Well-known defaults shipped with the app.
  static let builtinDefaults: [SavedAgentProfile] = AgentFamilyID.allCases.map(\.defaultProfile)

  init(userDefaults: UserDefaults = .standard, storageKey: String = SavedAgentProfiles.key) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
    if let loadedProfiles = loadProfiles() {
      profiles = Self.reconciledProfiles(from: loadedProfiles)
      if profiles != loadedProfiles {
        save()
      }
    } else {
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
      profiles[idx] = Self.migratedProfile(profile)
      save()
    }
  }

  func remove(at offsets: IndexSet) {
    for offset in offsets.sorted(by: >) where profiles.indices.contains(offset) {
      disableOrRemoveProfile(at: offset)
    }
    save()
  }

  func remove(id: String) {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
    disableOrRemoveProfile(at: index)
    save()
  }

  func setEnabled(_ isEnabled: Bool, for id: String) {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
    profiles[index].isEnabled = isEnabled
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

  private func loadProfiles() -> [SavedAgentProfile]? {
    guard let data = userDefaults.data(forKey: storageKey),
      let decoded = try? JSONDecoder().decode([SavedAgentProfile].self, from: data)
    else { return nil }
    return decoded
  }

  private func save() {
    if let data = try? JSONEncoder().encode(profiles) {
      userDefaults.set(data, forKey: storageKey)
    }
  }

  private func disableOrRemoveProfile(at index: Int) {
    if profiles[index].isBuiltIn {
      profiles[index].isEnabled = false
    } else {
      profiles.remove(at: index)
    }
  }

  private static func reconciledProfiles(from decoded: [SavedAgentProfile]) -> [SavedAgentProfile] {
    var profiles = decoded.map(Self.migratedProfile)
    for family in AgentFamilyID.allCases
    where !profiles.contains(where: { $0.familyID == family }) {
      var missingProfile = family.defaultProfile
      missingProfile.isEnabled = false
      profiles.append(missingProfile)
    }
    return profiles
  }

  private static func migratedProfile(_ profile: SavedAgentProfile) -> SavedAgentProfile {
    var migrated = profile
    if migrated.familyID == nil {
      migrated.familyID = AgentFamilyID.inferred(from: migrated)
    }
    if migrated.familyID == .codex,
      migrated.command == "codex",
      migrated.yoloFlag == "--yolo"
    {
      migrated.yoloFlag = "--full-auto"
    }
    return migrated
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

func sandboxAgentFamily(from command: String) -> String? {
  switch commandExecutableName(from: command).lowercased() {
  case "claude":
    "claude"
  case "codex":
    "codex"
  case "gemini":
    "gemini"
  default:
    nil
  }
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
