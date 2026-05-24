import Foundation

struct AntigravityAgentHarness: AgentHarness {
  let definition = AgentHarnessDefinition(
    familyID: .antigravity,
    name: "Antigravity CLI",
    command: "agy",
    icon: "antigravity",
    yoloFlag: "--dangerously-skip-permissions",
    promptArgumentTemplate: "",
    resumeArgumentTemplate: "",
    versionArguments: ["--version"]
  )

  let sandboxAgentFamily = "antigravity"
}
