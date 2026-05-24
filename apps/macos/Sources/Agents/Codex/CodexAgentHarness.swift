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
    versionArguments: ["--version"],
    parameterDefinitions: [
      AgentHarnessParameterDefinition(
        id: "model",
        label: "Model",
        input: .choice,
        argument: .option("-m"),
        choices: [
          AgentHarnessParameterChoice(value: "gpt-5.5", label: "GPT-5.5"),
          AgentHarnessParameterChoice(value: "gpt-5.5-pro", label: "GPT-5.5 Pro"),
          AgentHarnessParameterChoice(value: "gpt-5.4", label: "GPT-5.4"),
          AgentHarnessParameterChoice(value: "gpt-5.4-pro", label: "GPT-5.4 Pro"),
          AgentHarnessParameterChoice(value: "gpt-5.4-mini", label: "GPT-5.4 Mini"),
          AgentHarnessParameterChoice(value: "gpt-5.4-nano", label: "GPT-5.4 Nano"),
          AgentHarnessParameterChoice(value: "gpt-5.3-codex", label: "GPT-5.3 Codex"),
          AgentHarnessParameterChoice(value: "gpt-5.2", label: "GPT-5.2"),
          AgentHarnessParameterChoice(value: "gpt-5-mini", label: "GPT-5 Mini"),
          AgentHarnessParameterChoice(value: "gpt-5-nano", label: "GPT-5 Nano"),
        ],
        allowsCustomValue: true,
        placeholder: "Use Codex default",
        help: "Optional. Passed with -m."
      ),
      AgentHarnessParameterDefinition(
        id: "reasoning",
        label: "Reasoning",
        input: .choice,
        argument: .codexConfig("model_reasoning_effort"),
        choices: [
          AgentHarnessParameterChoice(value: "none", label: "None"),
          AgentHarnessParameterChoice(value: "low", label: "Low"),
          AgentHarnessParameterChoice(value: "medium", label: "Medium"),
          AgentHarnessParameterChoice(value: "high", label: "High"),
          AgentHarnessParameterChoice(value: "xhigh", label: "X High"),
        ],
        placeholder: "Use Codex default",
        help: "Optional. Passed as model_reasoning_effort config."
      ),
    ]
  )

  let sandboxAgentFamily = "codex"

  func displayVersion(rawOutput: String?) -> String? {
    guard let rawVersion = defaultDisplayVersion(rawOutput) else { return nil }
    return rawVersion.replacingOccurrences(of: "codex-cli ", with: "")
  }

  func dynamicParameterChoices(
    for parameterID: String,
    command: String
  ) async -> [AgentHarnessParameterChoice] {
    guard parameterID == "model" else { return [] }
    return await CodexModelCatalog.loadChoices(command: command)
  }

  func resumeSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord] {
    CodexSessionStore.loadSessionRecords(notBefore: notBefore)
  }
}
