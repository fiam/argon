import Foundation

struct GeminiAgentHarness: AgentHarness {
  let definition = AgentHarnessDefinition(
    familyID: .gemini,
    name: "Gemini CLI",
    command: "gemini",
    icon: "gemini",
    yoloFlag: "-y",
    promptArgumentTemplate: "",
    resumeArgumentTemplate: "--resume latest",
    versionArguments: ["--version"]
  )

  let sandboxAgentFamily = "gemini"

  func resumeSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord] {
    GeminiSessionStore.loadSessionRecords(notBefore: notBefore)
  }
}
