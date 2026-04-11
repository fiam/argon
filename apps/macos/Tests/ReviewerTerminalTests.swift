import Foundation
import Testing

@testable import Argon

@Suite("ReviewerTerminal")
struct ReviewerTerminalTests {

  @Test("launch shell command preserves quoting")
  func launchShellCommandPreservesQuoting() {
    let launch = ReviewerTerminalLaunch(
      processSpec: SandboxedProcessSpec(
        executable: "/opt/homebrew/bin/argon",
        args: [
          "sandbox", "exec", "--write-root", "/tmp/repo path", "--", "/bin/zsh", "-i", "-l", "-c",
          "echo 'hi'",
        ]
      ),
      environment: [:],
      currentDirectory: "/tmp/repo path"
    )

    #expect(
      launch.shellCommand
        == "'/opt/homebrew/bin/argon' 'sandbox' 'exec' '--write-root' '/tmp/repo path' '--' '/bin/zsh' '-i' '-l' '-c' 'echo '\\''hi'\\'''"
    )
    #expect(
      launch.ghosttyCommand
        == "'/opt/homebrew/bin/argon' 'sandbox' 'exec' '--write-root' '/tmp/repo path' '--' '/bin/zsh' '-i' '-l' '-c' 'echo '\\''hi'\\'''"
    )
  }

  @Test("terminal environment injects utf8 defaults when missing")
  func terminalEnvironmentInjectsUTF8DefaultsWhenMissing() {
    let environment = ReviewerTerminalLaunch.terminalEnvironment(
      base: [:],
      sessionId: "session-123",
      repoRoot: "/tmp/repo"
    )

    #expect(environment["ARGON_SESSION_ID"] == "session-123")
    #expect(environment["ARGON_REPO_ROOT"] == "/tmp/repo")
    #expect(environment["TERM"] == "xterm-256color")
    #expect(environment["LANG"]?.hasSuffix(".UTF-8") == true)
    #expect(environment["LC_CTYPE"] == environment["LANG"])
  }

  @Test("terminal environment preserves explicit locale overrides")
  func terminalEnvironmentPreservesExplicitLocaleOverrides() {
    let environment = ReviewerTerminalLaunch.terminalEnvironment(
      base: [
        "LANG": "pt_PT.UTF-8",
        "LC_CTYPE": "pt_PT.UTF-8",
        "LC_ALL": "C",
      ],
      sessionId: "session-123",
      repoRoot: "/tmp/repo"
    )

    #expect(environment["LANG"] == "pt_PT.UTF-8")
    #expect(environment["LC_CTYPE"] == "pt_PT.UTF-8")
    #expect(environment["LC_ALL"] == "C")
    #expect(environment["TERM"] == "xterm-256color")
    #expect(environment["COLORTERM"] == "truecolor")
  }

  @Test("terminal environment strips inherited terminal identity")
  func terminalEnvironmentStripsInheritedTerminalIdentity() {
    let environment = ReviewerTerminalLaunch.terminalEnvironment(
      base: [
        "TERM": "xterm-ghostty",
        "COLORTERM": "24bit",
        "TERMINFO": "/Applications/Ghostty.app/Contents/Resources/terminfo",
        "TERM_PROGRAM": "ghostty",
        "TERM_PROGRAM_VERSION": "1.3.1",
        "NO_COLOR": "1",
        "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources/ghostty",
        "GHOSTTY_SHELL_FEATURES": "path,title",
      ],
      sessionId: "session-123",
      repoRoot: "/tmp/repo"
    )

    #expect(environment["TERM"] == "xterm-256color")
    #expect(environment["COLORTERM"] == "truecolor")
    #expect(environment["TERMINFO"] == nil)
    #expect(environment["TERM_PROGRAM"] == nil)
    #expect(environment["TERM_PROGRAM_VERSION"] == nil)
    #expect(environment["NO_COLOR"] == nil)
    #expect(environment["GHOSTTY_RESOURCES_DIR"] == nil)
    #expect(environment["GHOSTTY_SHELL_FEATURES"] == nil)
  }
}
