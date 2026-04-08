import Foundation

@MainActor
enum ArgonSandbox {
  static func reviewerLaunchSpec(agent: ReviewerAgentInstance) -> SandboxedProcessSpec {
    let cli = ArgonCLI.cliPath()
    let sessionDir = SessionLoader.sessionsDirectory(repoRoot: agent.repoRoot)
    let launch = UserShell.launchSpec(command: agent.fullCommand)

    return SandboxedProcessSpec(
      executable: cli,
      args: [
        "sandbox", "exec",
        "--write-root", agent.repoRoot,
        "--write-root", sessionDir,
        "--",
        launch.executable,
      ] + launch.args
    )
  }
}
