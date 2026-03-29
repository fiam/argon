import Foundation
import Testing

@testable import Argon

@Suite("GitService")
struct GitServiceTests {

  @Test("runGit returns empty string for a failing command")
  func runGitReturnsEmptyForFailure() {
    // Pass an invalid git subcommand; git will exit non-zero and
    // produce no stdout, so runGit should return empty string.
    let result = GitService.runGit(["--no-such-flag-exists"])
    #expect(result == "")
  }

  @Test("resolveRef returns nil for nonexistent ref in non-repo directory")
  func resolveRefReturnsNilForNonRepo() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let result = GitService.resolveRef(repoRoot: tempDir.path, ref: "HEAD")
    #expect(result == nil)
  }
}
