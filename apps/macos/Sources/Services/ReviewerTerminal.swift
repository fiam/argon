import Foundation

struct ReviewerTerminalLaunch: Sendable {
  let processSpec: SandboxedProcessSpec
  let environment: [String: String]
  let currentDirectory: String

  private static let strippedTerminalIdentityKeys = [
    "NO_COLOR",
    "TERM",
    "COLORTERM",
    "TERMINFO",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "VTE_VERSION",
  ]

  @MainActor
  static func forAgent(
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
        sessionId: agent.sessionId,
        repoRoot: agent.repoRoot
      ),
      currentDirectory: agent.repoRoot
    )
  }

  static func terminalEnvironment(
    base: [String: String],
    sessionId: String,
    repoRoot: String
  ) -> [String: String] {
    var launchEnvironment = base
    sanitizeInheritedTerminalIdentity(&launchEnvironment)
    launchEnvironment["ARGON_SESSION_ID"] = sessionId
    launchEnvironment["ARGON_REPO_ROOT"] = repoRoot

    if let cliCmd = base["ARGON_CLI_CMD"], !cliCmd.isEmpty {
      launchEnvironment["ARGON_CLI_CMD"] = cliCmd
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

    for key in environment.keys where key.hasPrefix("GHOSTTY_") {
      environment.removeValue(forKey: key)
    }
  }

  private static func utf8LocaleIdentifier() -> String {
    let identifier = Locale.autoupdatingCurrent.identifier
      .replacingOccurrences(of: "-", with: "_")
    return identifier.isEmpty ? "en_US.UTF-8" : "\(identifier).UTF-8"
  }
}
