import Foundation
import Testing

@testable import Argon

@Suite("ArgonLib")
struct ArgonLibTests {
  @Test("highlightedText returns Swift styled spans")
  func highlightedTextReturnsStyledSpans() throws {
    let lines = try ArgonLib.highlightedText(
      text: "let value = 1\n",
      path: "src/lib.rs",
      theme: "base16-ocean.dark"
    )

    #expect(lines.count == 2)
    #expect(lines[0].map(\.text).joined() == "let value = 1")
    #expect(lines[0].contains { $0.fg != nil })
  }

  @Test("highlightedDiff surfaces argon-lib errors")
  func highlightedDiffSurfacesErrors() {
    do {
      _ = try ArgonLib.highlightedDiff(
        sessionId: "not-a-uuid",
        repoRoot: "/tmp",
        theme: "base16-ocean.dark"
      )
      Issue.record("Expected highlightedDiff to throw")
    } catch {
      #expect(String(describing: error).contains("invalid session id"))
    }
  }

  @Test("diff APIs return empty values for a missing repo root")
  func diffAPIsReturnEmptyValuesForMissingRepoRoot() throws {
    let missingRepo = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-missing-\(UUID().uuidString)")

    let files = try ArgonLib.diff(
      repoRoot: missingRepo.path,
      mode: .uncommitted,
      baseRef: "HEAD",
      headRef: "WORKTREE",
      mergeBaseSha: "HEAD"
    )
    let fingerprint = try ArgonLib.diffFingerprint(
      repoRoot: missingRepo.path,
      mode: .uncommitted,
      headRef: "WORKTREE",
      mergeBaseSha: "HEAD"
    )

    #expect(files.isEmpty)
    #expect(fingerprint.isEmpty)
  }
}
