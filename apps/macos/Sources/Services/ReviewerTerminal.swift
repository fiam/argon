import Foundation

struct TerminalLaunchConfiguration: Sendable {
  let processSpec: SandboxedProcessSpec
  let environment: [String: String]
  let currentDirectory: String

  private static let strippedTerminalIdentityKeys = [
    "NO_COLOR",
    "TERM",
    "COLORTERM",
    "TERMINFO",
    "VTE_VERSION",
  ]

  @MainActor
  static func forReviewerAgent(
    _ agent: ReviewerAgentInstance,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let processSpec: SandboxedProcessSpec
    if agent.sandboxEnabled {
      processSpec = ArgonSandbox.reviewerLaunchSpec(agent: agent)
    } else {
      processSpec = UserShell.launchSpec(command: agent.fullCommand, environment: environment)
    }

    return Self(
      processSpec: processSpec,
      environment: terminalEnvironment(
        base: environment,
        extraEnvironment: [
          "ARGON_SESSION_ID": agent.sessionId,
          "ARGON_REPO_ROOT": agent.repoRoot,
        ]
      ),
      currentDirectory: agent.repoRoot
    )
  }

  static func shell(
    currentDirectory: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    Self(
      processSpec: UserShell.interactiveLaunchSpec(environment: environment),
      environment: terminalEnvironment(base: environment),
      currentDirectory: currentDirectory
    )
  }

  static func sandboxedShell(
    currentDirectory: String,
    writableRoots: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let cli = ArgonCLI.cliPath()
    let launch = UserShell.interactiveLaunchSpec(environment: environment)
    let args =
      ["sandbox", "exec"]
      + ["--launch", "shell", "--interactive"]
      + writableRoots.flatMap { ["--write-root", $0] }
      + ["--", launch.executable]
      + launch.args

    return Self(
      processSpec: SandboxedProcessSpec(executable: cli, args: args),
      environment: terminalEnvironment(base: environment),
      currentDirectory: currentDirectory
    )
  }

  static func command(
    _ command: String,
    currentDirectory: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    Self(
      processSpec: UserShell.launchSpec(command: command, environment: environment),
      environment: terminalEnvironment(base: environment),
      currentDirectory: currentDirectory
    )
  }

  static func sandboxedCommand(
    _ command: String,
    currentDirectory: String,
    writableRoots: [String],
    launchKind: String = "command",
    agentFamily: String? = nil,
    sessionDirectory: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let cli = ArgonCLI.cliPath()
    let launch = UserShell.launchSpec(command: command, environment: environment)
    var args =
      ["sandbox", "exec", "--launch", launchKind]
      + writableRoots.flatMap { ["--write-root", $0] }
    if launchKind == "agent" || launchKind == "shell" {
      args += ["--interactive"]
    }
    if let agentFamily, !agentFamily.isEmpty {
      args += ["--agent-family", agentFamily]
    }
    if let sessionDirectory, !sessionDirectory.isEmpty {
      args += ["--session-dir", sessionDirectory]
    }
    args += ["--", launch.executable] + launch.args

    return Self(
      processSpec: SandboxedProcessSpec(executable: cli, args: args),
      environment: terminalEnvironment(base: environment),
      currentDirectory: currentDirectory
    )
  }

  static func terminalEnvironment(
    base: [String: String],
    sessionId: String,
    repoRoot: String
  ) -> [String: String] {
    terminalEnvironment(
      base: base,
      extraEnvironment: [
        "ARGON_SESSION_ID": sessionId,
        "ARGON_REPO_ROOT": repoRoot,
      ]
    )
  }

  static func terminalEnvironment(
    base: [String: String],
    extraEnvironment: [String: String] = [:]
  ) -> [String: String] {
    var launchEnvironment = base
    sanitizeInheritedTerminalIdentity(&launchEnvironment)

    for (key, value) in extraEnvironment where !value.isEmpty {
      launchEnvironment[key] = value
    }

    if let cliCmd = base["ARGON_CLI_CMD"], !cliCmd.isEmpty {
      launchEnvironment["ARGON_CLI_CMD"] = cliCmd
    }

    if launchEnvironment["TERM_PROGRAM"]?.isEmpty != false {
      launchEnvironment["TERM_PROGRAM"] = "ghostty"
    }

    launchEnvironment["TERM"] = "xterm-256color"
    launchEnvironment["COLORTERM"] = "truecolor"

    if launchEnvironment["LC_ALL"]?.isEmpty != false {
      let locale = utf8LocaleIdentifier()
      if launchEnvironment["LANG"]?.isEmpty != false {
        launchEnvironment["LANG"] = locale
      }
      if launchEnvironment["LC_CTYPE"]?.isEmpty != false {
        launchEnvironment["LC_CTYPE"] = launchEnvironment["LANG"] ?? locale
      }
    }

    return launchEnvironment
  }

  var shellCommand: String {
    ([processSpec.executable] + processSpec.args)
      .map(Self.shellQuote)
      .joined(separator: " ")
  }

  var ghosttyCommand: String {
    shellCommand
  }

  static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private static func sanitizeInheritedTerminalIdentity(
    _ environment: inout [String: String]
  ) {
    for key in strippedTerminalIdentityKeys {
      environment.removeValue(forKey: key)
    }
  }

  private static func utf8LocaleIdentifier() -> String {
    let identifier = Locale.autoupdatingCurrent.identifier
      .replacingOccurrences(of: "-", with: "_")
    return identifier.isEmpty ? "en_US.UTF-8" : "\(identifier).UTF-8"
  }
}

typealias ReviewerTerminalLaunch = TerminalLaunchConfiguration
