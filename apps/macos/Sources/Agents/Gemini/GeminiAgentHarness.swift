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
    versionArguments: ["--version"],
    parameterDefinitions: [
      AgentHarnessParameterDefinition(
        id: "model",
        label: "Model",
        input: .choice,
        argument: .option("--model"),
        choices: [
          AgentHarnessParameterChoice(value: "auto", label: "Auto"),
          AgentHarnessParameterChoice(value: "pro", label: "Pro"),
          AgentHarnessParameterChoice(value: "flash", label: "Flash"),
          AgentHarnessParameterChoice(value: "flash-lite", label: "Flash Lite"),
          AgentHarnessParameterChoice(
            value: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro Preview"),
          AgentHarnessParameterChoice(value: "gemini-3-pro-preview", label: "Gemini 3 Pro Preview"),
          AgentHarnessParameterChoice(
            value: "gemini-3-flash-preview", label: "Gemini 3 Flash Preview"),
          AgentHarnessParameterChoice(value: "gemini-2.5-pro", label: "Gemini 2.5 Pro"),
          AgentHarnessParameterChoice(value: "gemini-2.5-flash", label: "Gemini 2.5 Flash"),
          AgentHarnessParameterChoice(
            value: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash Lite"),
        ],
        allowsCustomValue: true,
        placeholder: "Use Gemini default",
        help: "Optional. Passed with --model."
      )
    ]
  )

  let sandboxAgentFamily = "gemini"

  func resumeSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord] {
    GeminiSessionStore.loadSessionRecords(notBefore: notBefore)
  }
}
