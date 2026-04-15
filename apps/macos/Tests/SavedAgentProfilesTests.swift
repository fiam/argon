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
  }
}
