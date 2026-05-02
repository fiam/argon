import Foundation

struct CodexAgentHarness: AgentHarness {
  let definition = AgentHarnessDefinition(
    familyID: .codex,
    name: "Codex",
    command: "codex",
    icon: "codex",
    yoloFlag: "--yolo",
    promptArgumentTemplate: "",
    resumeArgumentTemplate: "resume {{session_id}}",
    versionArguments: ["--version"]
  )

  let sandboxAgentFamily = "codex"

  func displayVersion(rawOutput: String?) -> String? {
    guard let rawVersion = defaultDisplayVersion(rawOutput) else { return nil }
    return rawVersion.replacingOccurrences(of: "codex-cli ", with: "")
  }

  func migratedProfile(_ profile: SavedAgentProfile) -> SavedAgentProfile {
    var migrated = profile
    if migrated.command == "codex", migrated.yoloFlag == "--full-auto" {
      migrated.yoloFlag = definition.yoloFlag
    }
    return migrated
  }

  func resumeSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord] {
    CodexSessionStore.loadSessionRecords(notBefore: notBefore)
  }
}
