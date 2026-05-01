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
      yoloFlag: "--full-auto"
    )

    #expect(profile.fullCommand(yolo: false, sandboxed: true) == "codex")
    #expect(profile.fullCommand(yolo: true, sandboxed: true) == "codex --full-auto")
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

  @Test("saved profiles require explicit prompt and resume templates when decoding")
  func savedProfilesRequireExplicitPromptAndResumeTemplatesWhenDecoding() {
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
        baseCommand: "codex --full-auto",
        resumeArgumentTemplate: "resume {{session_id}}",
        sessionID: "019da1c2-0e69-7c83-9f67-34c26af5fe33"
      ) == "codex --full-auto resume '019da1c2-0e69-7c83-9f67-34c26af5fe33'"
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
    #expect(commandExecutableName(from: "codex --full-auto") == "codex")
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

  @Test("stale builtin Codex auto-approve flag migrates")
  @MainActor
  func staleBuiltinCodexAutoApproveFlagMigrates() {
    let suiteName = "SavedAgentProfilesTests.migrate.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let staleProfiles = [
      SavedAgentProfile(
        id: "codex",
        name: "Codex",
        command: "codex",
        icon: "codex",
        yoloFlag: "--yolo",
        resumeArgumentTemplate: "resume {{session_id}}"
      )
    ]
    let data = try! JSONEncoder().encode(staleProfiles)
    defaults.set(data, forKey: suiteName)

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)

    #expect(profiles.profiles.first?.yoloFlag == "--full-auto")
  }

  @Test("older saved builtins infer family and enabled state")
  @MainActor
  func olderSavedBuiltinsInferFamilyAndEnabledState() {
    let suiteName = "SavedAgentProfilesTests.family.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let data = """
      [
        {
          "id": "codex",
          "name": "Codex",
          "command": "codex",
          "icon": "codex",
          "yoloFlag": "--yolo",
          "promptArgumentTemplate": "",
          "resumeArgumentTemplate": "resume {{session_id}}"
        }
      ]
      """.data(using: .utf8)!
    defaults.set(data, forKey: suiteName)

    let profiles = SavedAgentProfiles(userDefaults: defaults, storageKey: suiteName)
    let codex = profiles.profiles.first { $0.id == "codex" }

    #expect(codex?.familyID == .codex)
    #expect(codex?.isEnabled == true)
    #expect(codex?.yoloFlag == "--full-auto")
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
