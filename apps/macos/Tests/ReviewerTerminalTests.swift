import Darwin
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
          "sandbox", "exec", "--launch", "agent", "--interactive", "--write-root",
          "/tmp/repo path", "--", "/bin/zsh", "-i", "-l", "-c", "echo 'hi'",
        ]
      ),
      environment: [:],
      currentDirectory: "/tmp/repo path"
    )

    #expect(
      launch.shellCommand
        == "'/opt/homebrew/bin/argon' 'sandbox' 'exec' '--launch' 'agent' '--interactive' '--write-root' '/tmp/repo path' '--' '/bin/zsh' '-i' '-l' '-c' 'echo '\\''hi'\\'''"
    )
    #expect(
      launch.ghosttyCommand
        == "'/opt/homebrew/bin/argon' 'sandbox' 'exec' '--launch' 'agent' '--interactive' '--write-root' '/tmp/repo path' '--' '/bin/zsh' '-i' '-l' '-c' 'echo '\\''hi'\\'''"
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

  @Test("terminal environment preserves Ghostty identity for child processes")
  func terminalEnvironmentPreservesGhosttyIdentityForChildProcesses() {
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
    #expect(environment["TERM_PROGRAM"] == "ghostty")
    #expect(environment["TERM_PROGRAM_VERSION"] == "1.3.1")
    #expect(environment["NO_COLOR"] == nil)
    #expect(
      environment["GHOSTTY_RESOURCES_DIR"] == "/Applications/Ghostty.app/Contents/Resources/ghostty"
    )
    #expect(environment["GHOSTTY_SHELL_FEATURES"] == "path,title")
  }

  @Test("ghostty surface hides stripped inherited process environment")
  func ghosttySurfaceHidesStrippedInheritedProcessEnvironment() {
    let launchEnvironment = ReviewerTerminalLaunch.terminalEnvironment(
      base: [
        "NO_COLOR": "1",
        "TERM": "xterm-ghostty",
        "COLORTERM": "24bit",
        "TERMINFO": "/tmp/terminfo",
        "VTE_VERSION": "123",
      ],
      sessionId: "session-123",
      repoRoot: "/tmp/repo"
    )

    let hiddenKeys =
      ReviewerTerminalLaunch.processEnvironmentKeysToHideForGhosttySurface(
        launchEnvironment: launchEnvironment
      )

    #expect(hiddenKeys.contains("NO_COLOR"))
    #expect(hiddenKeys.contains("TERMINFO"))
    #expect(hiddenKeys.contains("VTE_VERSION"))
    #expect(!hiddenKeys.contains("TERM"))
    #expect(!hiddenKeys.contains("COLORTERM"))
  }

  @Test("hidden process environment scope restores values")
  func hiddenProcessEnvironmentScopeRestoresValues() {
    let key = "ARGON_TEST_HIDDEN_TERMINAL_ENV"
    let originalValue = getenv(key).map { String(cString: $0) }

    defer {
      if let originalValue {
        setenv(key, originalValue, 1)
      } else {
        unsetenv(key)
      }
    }

    setenv(key, "visible-before", 1)

    let valueInsideScope = ReviewerTerminalLaunch.withHiddenProcessEnvironment(
      keys: [key, key]
    ) {
      getenv(key).map { String(cString: $0) }
    }

    #expect(valueInsideScope == nil)
    #expect(getenv(key).map { String(cString: $0) } == "visible-before")
  }

  @Test("terminal environment defaults TERM_PROGRAM to ghostty")
  func terminalEnvironmentDefaultsTermProgramToGhostty() {
    let environment = ReviewerTerminalLaunch.terminalEnvironment(
      base: [:],
      sessionId: "session-123",
      repoRoot: "/tmp/repo"
    )

    #expect(environment["TERM_PROGRAM"] == "ghostty")
  }

  @Test("sandboxed command launch passes shell startup PATH to sandbox exec")
  func sandboxedCommandLaunchPassesShellStartupPathToSandboxExec() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let shellPath = tempDir.appendingPathComponent("fake-shell.sh")
    let script = """
      #!/bin/sh
      for last do :; done
      PATH="/custom/bin:/usr/bin:/bin"
      eval "$last"
      exit 0
      """
    try script.write(to: shellPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: shellPath.path
    )

    let launch = ReviewerTerminalLaunch.sandboxedCommand(
      "codex --yolo",
      currentDirectory: "/tmp/repo",
      writableRoots: ["/tmp/repo"],
      launchKind: "agent",
      agentFamily: "codex",
      environment: [
        "PATH": "/usr/bin:/bin",
        "SHELL": shellPath.path,
      ]
    )

    #expect(launch.environment["PATH"] == "/custom/bin:/usr/bin:/bin")
    #expect(launch.environment[ArgonLib.shellStartupPathResolvedEnvironmentKey] == "1")
    #expect(launch.processSpec.args.contains(shellPath.path))
    #expect(launch.processSpec.args.last == "codex --yolo")
  }
}
