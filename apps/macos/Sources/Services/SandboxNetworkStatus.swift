import Foundation

struct SandboxNetworkStatusSummary: Equatable, Sendable {
  let headline: String
  let detail: String?

  static func summarize(policy: ArgonCLI.SandboxExplainPolicy) -> Self {
    let proxiedHosts = policy.proxiedHosts
    let connectRuleCount = policy.connectRules.count
    let allowsDirectByDefault = policy.netDefault == .allow

    if proxiedHosts.isEmpty {
      if allowsDirectByDefault {
        return Self(
          headline: "Direct network allowed.",
          detail: nil
        )
      }

      if connectRuleCount == 0 {
        return Self(
          headline: "Network blocked.",
          detail: nil
        )
      }

      return Self(
        headline: directConnectHeadline(count: connectRuleCount),
        detail: nil
      )
    }

    let proxiedTraffic = proxiedTrafficDescription(hosts: proxiedHosts)
    if allowsDirectByDefault {
      return Self(
        headline: "Direct network allowed.",
        detail: "Proxy rules are configured too."
      )
    }

    if connectRuleCount == 0 || proxiedHosts.contains("*") {
      return Self(
        headline: "Proxied: \(proxiedTraffic).",
        detail: nil
      )
    }

    return Self(
      headline: "Proxied: \(proxiedTraffic).",
      detail: "\(connectRuleDescription(count: connectRuleCount)) also configured."
    )
  }

  private static func directConnectHeadline(count: Int) -> String {
    if count == 1 {
      return "1 direct connect rule configured."
    }
    return "\(count) direct connect rules configured."
  }

  private static func connectRuleDescription(count: Int) -> String {
    if count == 1 {
      return "1 direct connect rule"
    }
    return "\(count) direct connect rules"
  }

  private static func proxiedTrafficDescription(hosts: [String]) -> String {
    if hosts.contains("*") {
      return "all outbound web traffic"
    }

    if hosts.count == 1, let host = hosts.first {
      return "traffic for \(host)"
    }

    return "traffic matching \(hosts.count) host rules"
  }
}

enum SandboxNetworkStatusLoader {
  static func load(
    repoRoot: String,
    processExecutable: String,
    processArguments: [String]
  ) throws -> SandboxNetworkStatusSummary {
    guard processExecutable == ArgonCLI.cliPath() else {
      throw ArgonCLI.CLIError.commandFailed("Expected sandboxed Argon process spec")
    }

    let explain = try ArgonCLI.sandboxExplain(
      repoRoot: repoRoot,
      sandboxExecArguments: processArguments
    )
    return SandboxNetworkStatusSummary.summarize(policy: explain.policy)
  }
}
