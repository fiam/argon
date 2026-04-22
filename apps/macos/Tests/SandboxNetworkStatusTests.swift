import Foundation
import Testing

@testable import Argon

@Suite("SandboxNetworkStatus")
struct SandboxNetworkStatusTests {

  @Test("sandbox explain arguments reuse sandbox exec context flags")
  func sandboxExplainArgumentsReuseSandboxExecContextFlags() throws {
    let args = try ArgonCLI.sandboxExplainArguments(
      fromSandboxExecArguments: [
        "sandbox", "exec",
        "--launch", "agent",
        "--interactive",
        "--agent-family", "codex",
        "--session-dir", "/tmp/session",
        "--write-root", "/tmp/repo",
        "--write-root", "/tmp/session",
        "--",
        "/bin/zsh",
        "-i",
      ])

    #expect(
      args
        == [
          "sandbox", "explain", "--json",
          "--launch", "agent",
          "--interactive",
          "--agent-family", "codex",
          "--session-dir", "/tmp/session",
          "--write-root", "/tmp/repo",
          "--write-root", "/tmp/session",
        ])
  }

  @Test("sandbox explain arguments reject non sandbox launches")
  func sandboxExplainArgumentsRejectNonSandboxLaunches() {
    #expect(throws: ArgonCLI.CLIError.self) {
      try ArgonCLI.sandboxExplainArguments(
        fromSandboxExecArguments: ["/bin/zsh", "-i"]
      )
    }
  }

  @Test("summary reports blocked outbound access")
  func summaryReportsBlockedOutboundAccess() {
    let summary = SandboxNetworkStatusSummary.summarize(
      policy: .init(
        netDefault: .none,
        proxiedHosts: [],
        connectRules: []
      ))

    #expect(summary.headline == "Network blocked.")
    #expect(summary.detail == nil)
  }

  @Test("summary reports direct outbound access when nothing is proxied")
  func summaryReportsDirectOutboundAccessWhenNothingIsProxied() {
    let summary = SandboxNetworkStatusSummary.summarize(
      policy: .init(
        netDefault: .allow,
        proxiedHosts: [],
        connectRules: []
      ))

    #expect(summary.headline == "Direct network allowed.")
    #expect(summary.detail == nil)
  }

  @Test("summary reports wildcard proxying")
  func summaryReportsWildcardProxying() {
    let summary = SandboxNetworkStatusSummary.summarize(
      policy: .init(
        netDefault: .none,
        proxiedHosts: ["*"],
        connectRules: []
      ))

    #expect(summary.headline == "Proxied: all outbound web traffic.")
    #expect(summary.detail == nil)
  }

  @Test("summary reports mixed direct and proxied policy")
  func summaryReportsMixedDirectAndProxiedPolicy() {
    let summary = SandboxNetworkStatusSummary.summarize(
      policy: .init(
        netDefault: .allow,
        proxiedHosts: ["api.github.com"],
        connectRules: [.init(protocol: "tcp", target: "localhost:3000")]
      ))

    #expect(summary.headline == "Direct network allowed.")
    #expect(summary.detail == "Proxy rules are configured too.")
  }
}
