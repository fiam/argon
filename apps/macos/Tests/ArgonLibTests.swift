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

  @Test("workspaceMergeability returns branch topology")
  func workspaceMergeabilityReturnsBranchTopology() throws {
    let fixture = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-mergeability-\(UUID().uuidString)")
    let repo = fixture.appendingPathComponent("repo")
    let worktree = fixture.appendingPathComponent("feature")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])
    try "base\n".write(
      to: repo.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["add", "README.md"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])
    try git(repo, ["worktree", "add", "-b", "feature/topic", worktree.path, "HEAD"])

    try "feature\n".write(
      to: worktree.appendingPathComponent("feature.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(worktree, ["add", "feature.txt"])
    try git(worktree, ["commit", "-m", "feature"])

    let mergeability = try ArgonLib.workspaceMergeability(repoRoot: worktree.path)

    #expect(mergeability.status == .clean)
    #expect(mergeability.baseRef == "main")
    #expect(
      mergeability.topology == ArgonLib.WorkspaceBranchTopology(aheadCount: 1, behindCount: 0))
  }

  @discardableResult
  private func git(_ repo: URL, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repo.path] + args

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let stdoutData = try stdout.fileHandleForReading.readToEnd() ?? Data()
    let stderrData = try stderr.fileHandleForReading.readToEnd() ?? Data()
    let stdoutString = String(decoding: stdoutData, as: UTF8.self)
    let stderrString = String(decoding: stderrData, as: UTF8.self)

    guard process.terminationStatus == 0 else {
      throw ArgonLibTestError.gitFailed(args.joined(separator: " "), stderrString)
    }
    return stdoutString
  }
}

private enum ArgonLibTestError: Error {
  case gitFailed(String, String)
}
