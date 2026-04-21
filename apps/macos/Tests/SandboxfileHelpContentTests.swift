import Foundation
import Testing

@testable import Argon

@Suite("SandboxfileHelpContent")
struct SandboxfileHelpContentTests {
  @Test("settings overview mentions the home Sandboxfile layer")
  func settingsOverviewMentionsHomeSandboxfileLayer() {
    #expect(SandboxfileHelpContent.settingsOverview.contains("$HOME/.Sandboxfile"))
    #expect(SandboxfileHelpContent.settingsOverview.contains("after the repo-local sandbox files"))
  }

  @Test("default scaffold includes git builtin")
  func defaultScaffoldIncludesGitBuiltin() {
    #expect(SandboxfileHelpContent.defaultScaffold.contains("USE git"))
  }

  @Test("home sandboxfile note explains parent-directory ordering")
  func homeSandboxfileNoteExplainsParentDirectoryOrdering() {
    #expect(SandboxfileHelpContent.homeSandboxfileNote.contains("$HOME/.Sandboxfile"))
    #expect(SandboxfileHelpContent.homeSandboxfileNote.contains("applies after repo-local"))
    #expect(SandboxfileHelpContent.homeSandboxfileNote.contains("./Sandboxfile.local"))
  }
}
