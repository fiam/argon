import Foundation

struct ClaudeCodeAgentHarness: AgentHarness {
  let definition = AgentHarnessDefinition(
    familyID: .claudeCode,
    name: "Claude Code",
    command: "claude",
    icon: "claude",
    yoloFlag: "--dangerously-skip-permissions",
    promptArgumentTemplate: "",
    resumeArgumentTemplate: "-c",
    versionArguments: ["--version"]
  )

  let sandboxAgentFamily = "claude"

  func displayVersion(rawOutput: String?) -> String? {
    guard let rawVersion = defaultDisplayVersion(rawOutput) else { return nil }
    return rawVersion.replacingOccurrences(of: " (Claude Code)", with: "")
  }

  func resumeSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord] {
    ClaudeCodeSessionStore.loadSessionRecords(notBefore: notBefore)
  }
}
