import Foundation

enum AgentFamilyID: String, Codable, CaseIterable, Sendable {
  case claudeCode = "claude-code"
  case codex
  case gemini

  var defaultProfileID: String {
    rawValue
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

  init(
    familyID: AgentFamilyID,
    name: String,
    command: String,
    icon: String,
    yoloFlag: String,
    promptArgumentTemplate: String,
    resumeArgumentTemplate: String,
    versionArguments: [String]
  ) {
    self.familyID = familyID
    self.name = name
    self.command = command
    self.icon = icon
    self.yoloFlag = yoloFlag
    self.promptArgumentTemplate = promptArgumentTemplate
    self.resumeArgumentTemplate = resumeArgumentTemplate
    self.versionArguments = versionArguments
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
  func migratedProfile(_ profile: SavedAgentProfile) -> SavedAgentProfile
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

  func migratedProfile(_ profile: SavedAgentProfile) -> SavedAgentProfile {
    profile
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
    GeminiAgentHarness(),
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

  static func migratedProfile(_ profile: SavedAgentProfile) -> SavedAgentProfile {
    guard let familyID = profile.familyID else { return profile }
    return harness(for: familyID).migratedProfile(profile)
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
