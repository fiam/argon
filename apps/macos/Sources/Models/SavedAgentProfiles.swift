import Foundation

struct SavedAgentProfile: Codable, Identifiable, Hashable, Sendable {
  var id: String
  var kind: SavedAgentProfileKind
  var name: String
  var command: String
  var icon: String
  var isEnabled: Bool
  var parameterValues: AgentHarnessParameterValues
  /// Flags appended to the command to enable yolo mode.
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
    kind: SavedAgentProfileKind? = nil,
    familyID: AgentFamilyID? = nil,
    name: String,
    command: String,
    icon: String,
    isEnabled: Bool = true,
    parameterValues: AgentHarnessParameterValues = [:],
    yoloFlag: String,
    promptArgumentTemplate: String = "",
    resumeArgumentTemplate: String = ""
  ) {
    self.id = id
    self.kind = kind ?? familyID.map { .builtinDefault($0) } ?? .customCommand
    self.name = name
    self.command = command
    self.icon = icon
    self.isEnabled = isEnabled
    self.parameterValues = parameterValues
    self.yoloFlag = yoloFlag
    self.promptArgumentTemplate = promptArgumentTemplate
    self.resumeArgumentTemplate = resumeArgumentTemplate
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case name
    case command
    case icon
    case isEnabled
    case parameterValues
    case yoloFlag
    case promptArgumentTemplate
    case resumeArgumentTemplate
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.kind = try container.decode(SavedAgentProfileKind.self, forKey: .kind)
    self.name = try container.decode(String.self, forKey: .name)
    self.command = try container.decode(String.self, forKey: .command)
    self.icon = try container.decode(String.self, forKey: .icon)
    self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    self.parameterValues = try container.decode(
      AgentHarnessParameterValues.self, forKey: .parameterValues)
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
    try container.encode(kind, forKey: .kind)
    try container.encode(name, forKey: .name)
    try container.encode(command, forKey: .command)
    try container.encode(icon, forKey: .icon)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(parameterValues, forKey: .parameterValues)
    try container.encode(yoloFlag, forKey: .yoloFlag)
    try container.encode(promptArgumentTemplate, forKey: .promptArgumentTemplate)
    try container.encode(resumeArgumentTemplate, forKey: .resumeArgumentTemplate)
  }

  var familyID: AgentFamilyID? {
    kind.familyID
  }

  var isBuiltIn: Bool {
    if case .builtinDefault = kind {
      return true
    }
    return false
  }

  var isMutable: Bool {
    kind.isMutable
  }

  var availabilityCommand: String {
    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else { return "" }
    return commandExecutableToken(from: trimmedCommand)
  }

  /// Build the full command, optionally with yolo flags.
  func fullCommand(yolo: Bool, sandboxed: Bool = false, prompt: String? = nil) -> String {
    var components = [command]
    if case .harnessProfile(let familyID) = kind {
      components.append(
        contentsOf: AgentHarnesses.renderedArguments(
          for: familyID,
          values: parameterValues
        )
      )
    }
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

  var customizationSummary: String? {
    guard case .harnessProfile(let familyID) = kind else { return nil }
    return AgentHarnesses.parameterSummary(
      for: familyID,
      values: parameterValues
    )
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
    if let familyID = profile.familyID {
      return familyID
    }
    return allCases.first { family in
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
    profiles.append(Self.normalizedProfile(profile))
    save()
  }

  func update(_ profile: SavedAgentProfile) {
    if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[idx] = Self.normalizedProfile(profile)
      save()
    }
  }

  @discardableResult
  func duplicate(id: String) -> SavedAgentProfile? {
    guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
    let duplicate = Self.duplicatedProfile(from: profile)
    profiles.append(duplicate)
    save()
    return duplicate
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
    var profiles = decoded.map(Self.normalizedProfile)
    for family in AgentFamilyID.allCases
    where !profiles.contains(where: {
      if case .builtinDefault(let builtinFamily) = $0.kind {
        return builtinFamily == family
      }
      return false
    }) {
      var missingProfile = family.defaultProfile
      missingProfile.isEnabled = false
      profiles.append(missingProfile)
    }
    return profiles
  }

  private static func normalizedProfile(_ profile: SavedAgentProfile) -> SavedAgentProfile {
    switch profile.kind {
    case .builtinDefault(let familyID):
      var normalized = familyID.defaultProfile
      normalized.isEnabled = profile.isEnabled
      return normalized
    case .harnessProfile(let familyID):
      let defaultProfile = familyID.defaultProfile
      var normalized = profile
      normalized.kind = .harnessProfile(familyID)
      normalized.command = defaultProfile.command
      normalized.icon = defaultProfile.icon
      normalized.yoloFlag = defaultProfile.yoloFlag
      normalized.promptArgumentTemplate = defaultProfile.promptArgumentTemplate
      normalized.resumeArgumentTemplate = defaultProfile.resumeArgumentTemplate
      normalized.parameterValues = sanitizedParameterValues(
        profile.parameterValues,
        for: familyID
      )
      return normalized
    case .customCommand:
      var normalized = profile
      normalized.kind = .customCommand
      normalized.parameterValues = [:]
      normalized.icon = "agent"
      normalized.promptArgumentTemplate = ""
      normalized.resumeArgumentTemplate = ""
      return normalized
    }
  }

  private static func duplicatedProfile(from profile: SavedAgentProfile) -> SavedAgentProfile {
    if let familyID = profile.familyID {
      let defaultProfile = familyID.defaultProfile
      let duplicateName =
        profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? defaultProfile.name
        : "\(profile.name) Copy"
      return SavedAgentProfile(
        id: "profile-\(UUID().uuidString.prefix(8))",
        kind: .harnessProfile(familyID),
        name: duplicateName,
        command: defaultProfile.command,
        icon: defaultProfile.icon,
        parameterValues: profile.isBuiltIn ? [:] : profile.parameterValues,
        yoloFlag: defaultProfile.yoloFlag,
        promptArgumentTemplate: defaultProfile.promptArgumentTemplate,
        resumeArgumentTemplate: defaultProfile.resumeArgumentTemplate
      )
    }

    var duplicate = profile
    duplicate.id = "custom-\(UUID().uuidString.prefix(8))"
    duplicate.name =
      profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Custom Agent Copy"
      : "\(profile.name) Copy"
    return duplicate
  }

  private static func sanitizedParameterValues(
    _ values: AgentHarnessParameterValues,
    for familyID: AgentFamilyID
  ) -> AgentHarnessParameterValues {
    let definitions = AgentHarnesses.parameterDefinitions(for: familyID)
    let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    return values.reduce(into: [:]) { partialResult, entry in
      guard let definition = definitionsByID[entry.key] else { return }
      let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return }
      guard
        definition.input != .choice || definition.allowsCustomValue
          || definition.choices.contains(where: { $0.value == value })
      else { return }
      partialResult[entry.key] = value
    }
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

func shellQuote(_ value: String) -> String {
  let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
  return "'\(escaped)'"
}

func commandExecutableName(from command: String) -> String {
  let executable = commandExecutableToken(from: command)
  let basename = URL(fileURLWithPath: executable).lastPathComponent
  return basename.isEmpty ? "agent" : basename
}

func sandboxAgentFamily(from command: String) -> String? {
  AgentHarnesses.sandboxAgentFamily(matchingCommand: command)
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
