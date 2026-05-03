import Foundation
import Testing

@testable import Argon

@Suite("SavedAgentProfiles")
struct SavedAgentProfilesTests {

  @Test("sandboxed Claude launches keep the configured command")
  func sandboxedClaudeProfileStaysUnchanged() {
    let profile = SavedAgentProfile(
      id: "claude-code",
      name: "Claude Code",
      command: "claude",
      icon: "claude",
      yoloFlag: "--dangerously-skip-permissions"
    )

    #expect(profile.fullCommand(yolo: false, sandboxed: true) == "claude")
    #expect(
      profile.fullCommand(yolo: true, sandboxed: true)
        == "claude --dangerously-skip-permissions"
    )
  }

  @Test("non-Claude profiles are unchanged in sandbox")
  func sandboxedNonClaudeProfileStaysUnchanged() {
    let profile = SavedAgentProfile(
      id: "codex",
      name: "Codex",
      command: "codex",
      icon: "codex",
      yoloFlag: "--yolo"
    )

    #expect(profile.fullCommand(yolo: false, sandboxed: true) == "codex")
    #expect(profile.fullCommand(yolo: true, sandboxed: true) == "codex --yolo")
  }

  @Test("prompt templates can place the prompt before trailing flags")
  func promptTemplatesPlaceThePromptWhereRequested() {
    let profile = SavedAgentProfile(
      id: "custom",
      name: "Custom",
      command: "runner",
      icon: "terminal",
      yoloFlag: "--fast",
      promptArgumentTemplate: "--prompt {{prompt}} --json"
    )

    #expect(
      profile.fullCommand(yolo: true, prompt: "review this")
        == "runner --fast --prompt 'review this' --json"
    )
  }

  @Test("saved profiles require explicit profile kind when decoding")
  func savedProfilesRequireExplicitProfileKindWhenDecoding() {
    let data = """
      [
        {
          "id": "codex",
          "name": "Codex",
          "command": "codex",
          "icon": "codex",
          "yoloFlag": "--yolo"
        }
      ]
      """.data(using: .utf8)!

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([SavedAgentProfile].self, from: data)
    }
  }

  @Test("resume templates render with optional session placeholders")
  func resumeTemplatesRenderWithOptionalSessionPlaceholders() {
    #expect(
      renderAgentResumeCommand(
        baseCommand: "codex --yolo",
        resumeArgumentTemplate: "resume {{session_id}}",
        sessionID: "019da1c2-0e69-7c83-9f67-34c26af5fe33"
      ) == "codex --yolo resume '019da1c2-0e69-7c83-9f67-34c26af5fe33'"
    )
    #expect(
      renderAgentResumeCommand(
        baseCommand: "claude --dangerously-skip-permissions",
        resumeArgumentTemplate: "-c",
        sessionID: nil
      ) == "claude --dangerously-skip-permissions -c"
    )
    #expect(
      renderAgentResumeCommand(
        baseCommand: "codex",
        resumeArgumentTemplate: "resume {{session_id}}",
        sessionID: nil
      ) == nil
    )
  }

  @Test("command executable names strip paths and preserve quoted argv0")
  func commandExecutableNamesUseArgvZero() {
    #expect(commandExecutableName(from: "codex --yolo") == "codex")
    #expect(commandExecutableName(from: "/opt/tools/claude --print") == "claude")
    #expect(commandExecutableName(from: "'/Applications/My Tool/bin/agent' --json") == "agent")
    #expect(commandExecutableToken(from: "/opt/tools/claude --print") == "/opt/tools/claude")
    #expect(
      commandExecutableToken(from: "'/Applications/My Tool/bin/agent' --json")
        == "/Applications/My Tool/bin/agent"
    )
  }

  @Test("known harnesses parse display versions")
  func knownHarnessesParseDisplayVersions() {
    #expect(
      AgentHarnesses.displayVersion(for: .codex, rawOutput: "codex-cli 0.125.0") == "0.125.0"
    )
    #expect(
      AgentHarnesses.displayVersion(for: .claudeCode, rawOutput: "2.1.98 (Claude Code)")
        == "2.1.98"
    )
    #expect(AgentHarnesses.displayVersion(for: .gemini, rawOutput: "0.38.2") == "0.38.2")
  }

  @Test("builtin defaults are immutable and render no harness parameters")
  func builtinDefaultsAreImmutableAndRenderNoHarnessParameters() {
    var profile = AgentFamilyID.codex.defaultProfile
    #expect(profile.parameterValues.isEmpty)

    profile.parameterValues = [
      "model": "gpt-5.5",
      "reasoning": "high",
    ]

    #expect(profile.kind == .builtinDefault(.codex))
    #expect(profile.isMutable == false)
    #expect(profile.fullCommand(yolo: false) == "codex")
    #expect(profile.fullCommand(yolo: true) == "codex --yolo")
  }

  @Test("duplicating a builtin creates a mutable harness profile")
  @MainActor
  func duplicatingBuiltinCreatesMutableHarnessProfile() throws {
    let suiteName = "SavedAgentProfilesTests.duplicate.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)
    let duplicate = try #require(profiles.duplicate(id: "codex"))

    #expect(duplicate.kind == .harnessProfile(.codex))
    #expect(duplicate.isMutable)
    #expect(duplicate.name == "Codex Copy")
    #expect(duplicate.parameterValues.isEmpty)
    #expect(duplicate.fullCommand(yolo: false) == "codex")

    var edited = duplicate
    edited.parameterValues = [
      "model": "gpt-5.5",
      "reasoning": "high",
    ]
    profiles.update(edited)

    let saved = try #require(profiles.profiles.first { $0.id == duplicate.id })
    #expect(
      saved.fullCommand(yolo: false)
        == "codex -m 'gpt-5.5' -c 'model_reasoning_effort=\"high\"'"
    )
    #expect(
      saved.fullCommand(yolo: true)
        == "codex -m 'gpt-5.5' -c 'model_reasoning_effort=\"high\"' --yolo"
    )
    #expect(saved.customizationSummary == "Model: GPT-5.5, Reasoning: High")
  }

  @Test("profile customization summaries are only shown for harness parameter overrides")
  func profileCustomizationSummariesDescribeHarnessParameters() {
    var builtIn = AgentFamilyID.codex.defaultProfile
    builtIn.parameterValues = ["model": "gpt-5.5"]
    #expect(builtIn.customizationSummary == nil)

    let custom = SavedAgentProfile(
      id: "custom-agent",
      name: "Custom Agent",
      command: "agent --model x",
      icon: "agent",
      yoloFlag: ""
    )
    #expect(custom.customizationSummary == nil)

    let harnessProfile = SavedAgentProfile(
      id: "codex-high",
      kind: .harnessProfile(.codex),
      name: "Codex High",
      command: "codex",
      icon: "codex",
      parameterValues: ["model": "unlisted-model", "reasoning": "xhigh"],
      yoloFlag: "--yolo"
    )

    #expect(
      harnessProfile.customizationSummary
        == "Model: unlisted-model, Reasoning: X High"
    )
  }

  @Test("harness profiles sanitize parameters through harness definitions")
  @MainActor
  func harnessProfilesSanitizeParametersThroughHarnessDefinitions() throws {
    let suiteName = "SavedAgentProfilesTests.params.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)
    profiles.add(
      SavedAgentProfile(
        id: "codex-gpt",
        kind: .harnessProfile(.codex),
        name: "Codex GPT",
        command: "ignored",
        icon: "agent",
        parameterValues: [
          "model": "custom-codex-model",
          "reasoning": "ultra",
          "unknown": "drop",
        ],
        yoloFlag: "--ignored",
        promptArgumentTemplate: "--ignored {{prompt}}",
        resumeArgumentTemplate: "--ignored"
      )
    )

    let saved = try #require(profiles.profiles.first { $0.id == "codex-gpt" })

    #expect(saved.kind == .harnessProfile(.codex))
    #expect(saved.command == "codex")
    #expect(saved.icon == "codex")
    #expect(saved.yoloFlag == "--yolo")
    #expect(saved.promptArgumentTemplate == "")
    #expect(saved.resumeArgumentTemplate == "resume {{session_id}}")
    #expect(saved.parameterValues == ["model": "custom-codex-model"])
    #expect(saved.fullCommand(yolo: false) == "codex -m 'custom-codex-model'")
  }

  @Test("saved builtins use harness defaults but keep enabled state")
  @MainActor
  func savedBuiltinsUseHarnessDefaultsButKeepEnabledState() {
    let suiteName = "SavedAgentProfilesTests.defaults.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let staleProfiles = [
      SavedAgentProfile(
        id: "codex",
        familyID: .codex,
        name: "Edited Codex",
        command: "codex-nightly",
        icon: "agent",
        isEnabled: false,
        parameterValues: ["model": "gpt-5.5"],
        yoloFlag: "--full-auto",
        promptArgumentTemplate: "--prompt {{prompt}}",
        resumeArgumentTemplate: "--resume latest"
      )
    ]
    let data = try! JSONEncoder().encode(staleProfiles)
    defaults.set(data, forKey: suiteName)

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)
    let codex = profiles.profiles.first { $0.familyID == .codex }

    #expect(codex?.id == "codex")
    #expect(codex?.kind == .builtinDefault(.codex))
    #expect(codex?.name == "Codex")
    #expect(codex?.command == "codex")
    #expect(codex?.icon == "codex")
    #expect(codex?.isEnabled == false)
    #expect(codex?.parameterValues == [:])
    #expect(codex?.yoloFlag == "--yolo")
    #expect(codex?.promptArgumentTemplate == "")
    #expect(codex?.resumeArgumentTemplate == "resume {{session_id}}")
  }

  @Test("unreadable profile payload resets to current defaults")
  @MainActor
  func unreadableProfilePayloadResetsToCurrentDefaults() throws {
    let suiteName = "SavedAgentProfilesTests.unreadable.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let legacyJSON = """
      [
        {
          "id": "codex",
          "familyID": "codex",
          "name": "Edited Codex",
          "command": "codex-nightly",
          "icon": "agent",
          "isEnabled": true,
          "yoloFlag": "--full-auto",
          "promptArgumentTemplate": "--prompt {{prompt}}",
          "resumeArgumentTemplate": "--resume latest",
          "keepRunningWhileThinking": true
        }
      ]
      """
    defaults.set(Data(legacyJSON.utf8), forKey: suiteName)

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)
    let savedData = try #require(defaults.data(forKey: suiteName))
    let savedJSON = String(decoding: savedData, as: UTF8.self)

    #expect(profiles.profiles == SavedAgentProfiles.builtinDefaults)
    #expect(!savedJSON.contains("\"keepRunningWhileThinking\""))
  }

  @Test("missing builtins are restored disabled")
  @MainActor
  func missingBuiltinsAreRestoredDisabled() {
    let suiteName = "SavedAgentProfilesTests.restore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let data = try! JSONEncoder().encode([AgentFamilyID.codex.defaultProfile])
    defaults.set(data, forKey: suiteName)

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)

    #expect(profiles.profiles.count == 3)
    #expect(profiles.profiles.first { $0.familyID == .codex }?.isEnabled == true)
    #expect(profiles.profiles.first { $0.familyID == .claudeCode }?.isEnabled == false)
    #expect(profiles.profiles.first { $0.familyID == .gemini }?.isEnabled == false)
  }

  @Test("builtins disable while custom profiles delete")
  @MainActor
  func builtinsDisableWhileCustomProfilesDelete() {
    let suiteName = "SavedAgentProfilesTests.disable.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)
    profiles.remove(id: "codex")

    #expect(profiles.profiles.first { $0.id == "codex" }?.isEnabled == false)
    #expect(profiles.enabledProfiles.map(\.id) == ["claude-code", "gemini"])

    profiles.add(
      SavedAgentProfile(
        id: "custom-agent",
        name: "Custom Agent",
        command: "agent",
        icon: "agent",
        yoloFlag: "",
        promptArgumentTemplate: "",
        resumeArgumentTemplate: ""
      )
    )
    profiles.remove(id: "custom-agent")

    #expect(profiles.profiles.contains { $0.id == "custom-agent" } == false)
  }

  @Test("reset to defaults reenables builtins")
  @MainActor
  func resetToDefaultsReenablesBuiltins() {
    let suiteName = "SavedAgentProfilesTests.reset.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)
    profiles.remove(id: "codex")
    profiles.resetToDefaults()

    #expect(profiles.profiles.allSatisfy { $0.isEnabled })
    #expect(profiles.profiles.compactMap(\.familyID) == [.claudeCode, .codex, .gemini])
  }

  @Test("moving profiles persists the new order")
  @MainActor
  func movingProfilesPersistsTheNewOrder() {
    let suiteName = "SavedAgentProfilesTests.move.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)
    profiles.move(from: IndexSet(integer: 2), to: 0)

    #expect(profiles.profiles.map(\.id) == ["gemini", "claude-code", "codex"])

    let reloaded = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)
    #expect(reloaded.profiles.map(\.id) == ["gemini", "claude-code", "codex"])

    defaults.removePersistentDomain(forName: suiteName)
  }
}
