import Foundation

enum AgentFamilyID: String, Codable, CaseIterable, Sendable {
  case claudeCode = "claude-code"
  case codex
  case antigravity

  var defaultProfileID: String {
    rawValue
  }
}

enum SavedAgentProfileKind: Codable, Hashable, Sendable {
  case builtinDefault(AgentFamilyID)
  case harnessProfile(AgentFamilyID)
  case customCommand

  private enum CodingKeys: String, CodingKey {
    case discriminator
    case familyID
  }

  private enum Discriminator: String, Codable {
    case builtinDefault
    case harnessProfile
    case customCommand
  }

  var familyID: AgentFamilyID? {
    switch self {
    case .builtinDefault(let familyID), .harnessProfile(let familyID):
      familyID
    case .customCommand:
      nil
    }
  }

  var isMutable: Bool {
    switch self {
    case .builtinDefault:
      false
    case .harnessProfile, .customCommand:
      true
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Discriminator.self, forKey: .discriminator) {
    case .builtinDefault:
      self = .builtinDefault(try container.decode(AgentFamilyID.self, forKey: .familyID))
    case .harnessProfile:
      self = .harnessProfile(try container.decode(AgentFamilyID.self, forKey: .familyID))
    case .customCommand:
      self = .customCommand
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .builtinDefault(let familyID):
      try container.encode(Discriminator.builtinDefault, forKey: .discriminator)
      try container.encode(familyID, forKey: .familyID)
    case .harnessProfile(let familyID):
      try container.encode(Discriminator.harnessProfile, forKey: .discriminator)
      try container.encode(familyID, forKey: .familyID)
    case .customCommand:
      try container.encode(Discriminator.customCommand, forKey: .discriminator)
    }
  }
}

typealias AgentHarnessParameterValues = [String: String]

struct AgentHarnessParameterChoice: Codable, Hashable, Sendable, Identifiable {
  let value: String
  let label: String
  let help: String?

  var id: String { value }

  init(value: String, label: String? = nil, help: String? = nil) {
    self.value = value
    self.label = label ?? value
    self.help = help
  }
}

enum AgentHarnessParameterInput: String, Codable, Hashable, Sendable {
  case text
  case choice
  case boolean
}

struct AgentHarnessArgumentTemplate: Codable, Hashable, Sendable {
  enum Style: String, Codable, Hashable, Sendable {
    case flag
    case option
    case codexConfig
  }

  let style: Style
  let name: String

  static func flag(_ name: String) -> Self {
    Self(style: .flag, name: name)
  }

  static func option(_ name: String) -> Self {
    Self(style: .option, name: name)
  }

  static func codexConfig(_ name: String) -> Self {
    Self(style: .codexConfig, name: name)
  }
}

struct AgentHarnessParameterDefinition: Codable, Hashable, Sendable, Identifiable {
  let id: String
  let label: String
  let input: AgentHarnessParameterInput
  let argument: AgentHarnessArgumentTemplate
  let choices: [AgentHarnessParameterChoice]
  let allowsCustomValue: Bool
  let placeholder: String
  let help: String?

  init(
    id: String,
    label: String,
    input: AgentHarnessParameterInput,
    argument: AgentHarnessArgumentTemplate,
    choices: [AgentHarnessParameterChoice] = [],
    allowsCustomValue: Bool = false,
    placeholder: String = "",
    help: String? = nil
  ) {
    self.id = id
    self.label = label
    self.input = input
    self.argument = argument
    self.choices = choices
    self.allowsCustomValue = allowsCustomValue
    self.placeholder = placeholder
    self.help = help
  }
}

struct AgentResumeSessionRecord: Sendable, Equatable {
  let familyID: AgentFamilyID
  let sessionID: String
  let cwd: String
  let startedAt: Date
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
  let parameterDefinitions: [AgentHarnessParameterDefinition]

  init(
    familyID: AgentFamilyID,
    name: String,
    command: String,
    icon: String,
    yoloFlag: String,
    promptArgumentTemplate: String,
    resumeArgumentTemplate: String,
    versionArguments: [String],
    parameterDefinitions: [AgentHarnessParameterDefinition] = []
  ) {
    self.familyID = familyID
    self.name = name
    self.command = command
    self.icon = icon
    self.yoloFlag = yoloFlag
    self.promptArgumentTemplate = promptArgumentTemplate
    self.resumeArgumentTemplate = resumeArgumentTemplate
    self.versionArguments = versionArguments
    self.parameterDefinitions = parameterDefinitions
  }

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

protocol AgentHarness: Sendable {
  var definition: AgentHarnessDefinition { get }
  var sandboxAgentFamily: String { get }

  func displayVersion(rawOutput: String?) -> String?
  func matchesCommand(_ command: String) -> Bool
  func renderedArguments(for values: AgentHarnessParameterValues) -> [String]
  func resumeSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord]
}

extension AgentHarness {
  var sandboxAgentFamily: String {
    definition.command
  }

  func displayVersion(rawOutput: String?) -> String? {
    defaultDisplayVersion(rawOutput)
  }

  func matchesCommand(_ command: String) -> Bool {
    commandExecutableName(from: command).lowercased() == definition.command.lowercased()
  }

  func renderedArguments(for values: AgentHarnessParameterValues) -> [String] {
    renderedHarnessArguments(
      definitions: definition.parameterDefinitions,
      values: values
    )
  }

  func resumeSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord] {
    []
  }

  func defaultDisplayVersion(_ rawOutput: String?) -> String? {
    guard let rawOutput else { return nil }
    let firstLine = rawOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? rawOutput
    let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

enum AgentHarnesses {
  nonisolated(unsafe) static var resumeSessionRecordsProvider:
    (@Sendable () -> [AgentResumeSessionRecord])?

  private static let harnesses: [any AgentHarness] = [
    ClaudeCodeAgentHarness(),
    CodexAgentHarness(),
    AntigravityAgentHarness(),
  ]

  private static let harnessesByFamily: [AgentFamilyID: any AgentHarness] = Dictionary(
    uniqueKeysWithValues: harnesses.map { harness in
      (harness.definition.familyID, harness)
    }
  )

  static func harness(for familyID: AgentFamilyID) -> any AgentHarness {
    harnessesByFamily[familyID]!
  }

  static func definition(for familyID: AgentFamilyID) -> AgentHarnessDefinition {
    harness(for: familyID).definition
  }

  static func displayVersion(for familyID: AgentFamilyID, rawOutput: String?) -> String? {
    harness(for: familyID).displayVersion(rawOutput: rawOutput)
  }

  static func parameterDefinitions(for familyID: AgentFamilyID) -> [AgentHarnessParameterDefinition]
  {
    definition(for: familyID).parameterDefinitions
  }

  static func renderedArguments(
    for familyID: AgentFamilyID,
    values: AgentHarnessParameterValues
  ) -> [String] {
    harness(for: familyID).renderedArguments(for: values)
  }

  static func parameterSummary(
    for familyID: AgentFamilyID,
    values: AgentHarnessParameterValues
  ) -> String? {
    let parts = parameterDefinitions(for: familyID).compactMap { definition -> String? in
      guard let value = values[definition.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      else { return nil }

      let displayValue: String
      if definition.input == .boolean {
        guard value == "true" else { return nil }
        displayValue = "On"
      } else {
        displayValue = definition.choices.first { $0.value == value }?.label ?? value
      }
      return "\(definition.label): \(displayValue)"
    }

    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: ", ")
  }

  static func sandboxAgentFamily(for familyID: AgentFamilyID) -> String {
    harness(for: familyID).sandboxAgentFamily
  }

  static func familyID(matchingCommand command: String) -> AgentFamilyID? {
    harnesses.first { $0.matchesCommand(command) }?.definition.familyID
  }

  static func sandboxAgentFamily(matchingCommand command: String) -> String? {
    guard let familyID = familyID(matchingCommand: command) else { return nil }
    return sandboxAgentFamily(for: familyID)
  }

  static func resumeSessionRecords(
    for familyID: AgentFamilyID,
    notBefore: Date
  ) -> [AgentResumeSessionRecord] {
    if let resumeSessionRecordsProvider {
      return resumeSessionRecordsProvider()
        .filter { $0.familyID == familyID && $0.startedAt >= notBefore }
    }
    return harness(for: familyID).resumeSessionRecords(notBefore: notBefore)
  }
}

func renderedHarnessArguments(
  definitions: [AgentHarnessParameterDefinition],
  values: AgentHarnessParameterValues
) -> [String] {
  var arguments: [String] = []

  for definition in definitions {
    guard let rawValue = values[definition.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty
    else { continue }

    switch definition.input {
    case .boolean:
      guard rawValue == "true" else { continue }
      arguments.append(definition.argument.name)
    case .text, .choice:
      guard isAcceptedHarnessValue(rawValue, for: definition) else { continue }
      arguments.append(contentsOf: renderedHarnessArgument(definition.argument, value: rawValue))
    }
  }

  return arguments
}

private func isAcceptedHarnessValue(
  _ value: String,
  for definition: AgentHarnessParameterDefinition
) -> Bool {
  guard definition.input == .choice, !definition.allowsCustomValue else { return true }
  return definition.choices.contains { $0.value == value }
}

private func renderedHarnessArgument(
  _ template: AgentHarnessArgumentTemplate,
  value: String
) -> [String] {
  switch template.style {
  case .flag:
    return value == "true" ? [template.name] : []
  case .option:
    return [template.name, shellQuote(value)]
  case .codexConfig:
    let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
    return ["-c", shellQuote("\(template.name)=\"\(escapedValue)\"")]
  }
}
