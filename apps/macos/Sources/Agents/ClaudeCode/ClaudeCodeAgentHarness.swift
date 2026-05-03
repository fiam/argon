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
    versionArguments: ["--version"],
    parameterDefinitions: [
      AgentHarnessParameterDefinition(
        id: "model",
        label: "Model",
        input: .choice,
        argument: .option("--model"),
        choices: [
          AgentHarnessParameterChoice(value: "default", label: "Default"),
          AgentHarnessParameterChoice(value: "sonnet", label: "Sonnet"),
          AgentHarnessParameterChoice(value: "opus", label: "Opus"),
          AgentHarnessParameterChoice(value: "haiku", label: "Haiku"),
          AgentHarnessParameterChoice(value: "sonnet[1m]", label: "Sonnet 1M"),
          AgentHarnessParameterChoice(value: "opus[1m]", label: "Opus 1M"),
          AgentHarnessParameterChoice(value: "opusplan", label: "Opus Plan"),
          AgentHarnessParameterChoice(value: "claude-opus-4-7", label: "Claude Opus 4.7"),
          AgentHarnessParameterChoice(value: "claude-opus-4-6", label: "Claude Opus 4.6"),
          AgentHarnessParameterChoice(value: "claude-sonnet-4-6", label: "Claude Sonnet 4.6"),
          AgentHarnessParameterChoice(value: "claude-sonnet-4-5", label: "Claude Sonnet 4.5"),
        ],
        allowsCustomValue: true,
        placeholder: "Use Claude default",
        help: "Optional. Passed with --model."
      ),
      AgentHarnessParameterDefinition(
        id: "effort",
        label: "Effort",
        input: .choice,
        argument: .option("--effort"),
        choices: [
          AgentHarnessParameterChoice(value: "low", label: "Low"),
          AgentHarnessParameterChoice(value: "medium", label: "Medium"),
          AgentHarnessParameterChoice(value: "high", label: "High"),
          AgentHarnessParameterChoice(value: "xhigh", label: "X High"),
          AgentHarnessParameterChoice(value: "max", label: "Max"),
        ],
        placeholder: "Use Claude default",
        help: "Optional. Passed with --effort."
      ),
    ]
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
