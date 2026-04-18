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

  @Test("saved profiles default missing prompt templates during decoding")
  func savedProfilesDefaultMissingPromptTemplatesDuringDecoding() throws {
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

    let decoded = try JSONDecoder().decode([SavedAgentProfile].self, from: data)

    #expect(decoded.count == 1)
    #expect(decoded[0].promptArgumentTemplate == "")
    #expect(decoded[0].resumeArgumentTemplate == "")
  }

  @Test("legacy built-in profiles get resume defaults only when field was missing")
  func legacyBuiltinsGetResumeDefaultsWhenFieldWasMissing() throws {
    let legacyData = """
      [
        {
          "id": "codex",
          "name": "Codex",
          "command": "codex",
          "icon": "codex",
          "yoloFlag": "--yolo"
        },
        {
          "id": "custom",
          "name": "Custom",
          "command": "custom-agent",
          "icon": "terminal",
          "yoloFlag": ""
        }
      ]
      """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode([SavedAgentProfile].self, from: legacyData)
    let missingIDs = SavedAgentProfiles.missingResumeFieldProfileIDs(from: legacyData) ?? []
    let migrated = SavedAgentProfiles.applyingLegacyResumeDefaults(
      to: decoded,
      missingResumeFieldProfileIDs: missingIDs
    )

    #expect(
      migrated.first(where: { $0.id == "codex" })?.resumeArgumentTemplate == "resume {{session_id}}"
    )
    #expect(migrated.first(where: { $0.id == "custom" })?.resumeArgumentTemplate == "")
  }

  @Test("explicitly empty resume templates are preserved")
  func explicitlyEmptyResumeTemplatesArePreserved() throws {
    let currentData = """
      [
        {
          "id": "codex",
          "name": "Codex",
          "command": "codex",
          "icon": "codex",
          "yoloFlag": "--yolo",
          "resumeArgumentTemplate": ""
        }
      ]
      """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode([SavedAgentProfile].self, from: currentData)
    let missingIDs = SavedAgentProfiles.missingResumeFieldProfileIDs(from: currentData) ?? []
    let migrated = SavedAgentProfiles.applyingLegacyResumeDefaults(
      to: decoded,
      missingResumeFieldProfileIDs: missingIDs
    )

    #expect(missingIDs.isEmpty)
    #expect(migrated[0].resumeArgumentTemplate == "")
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
}
