import Testing

@testable import Argon

@Suite("SavedAgentProfiles")
struct SavedAgentProfilesTests {

  @Test("sandboxed Claude launches append bare mode")
  func sandboxedClaudeAppendsBareMode() {
    let profile = SavedAgentProfile(
      id: "claude-code",
      name: "Claude Code",
      command: "claude",
      icon: "claude",
      yoloFlag: "--dangerously-skip-permissions"
    )

    #expect(profile.fullCommand(yolo: false, sandboxed: true) == "claude --bare")
    #expect(
      profile.fullCommand(yolo: true, sandboxed: true)
        == "claude --dangerously-skip-permissions --bare"
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
}
