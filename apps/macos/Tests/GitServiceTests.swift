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

  @Test("resolveCommitTarget reviews the latest commit only")
  func resolveCommitTargetUsesParentAndHead() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])

    try "one\ncommitted\n".write(
      to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["commit", "-am", "second"])

    let expectedBase = try git(repo, ["rev-parse", "HEAD^"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let expectedHead = try git(repo, ["rev-parse", "HEAD"]).trimmingCharacters(
      in: .whitespacesAndNewlines)

    let target = GitService.resolveCommitTarget(repoRoot: repo.path)

    #expect(target?.mode == .commit)
    #expect(target?.baseRef == expectedBase)
    #expect(target?.headRef == expectedHead)
    #expect(target?.mergeBaseSha == expectedHead)
  }

  @Test("commit diff excludes later working tree changes")
  func commitDiffExcludesWorkingTreeChanges() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])

    try "one\ncommitted\n".write(
      to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["commit", "-am", "second"])

    try "one\ncommitted\nworking\n".write(
      to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

    guard let target = GitService.resolveCommitTarget(repoRoot: repo.path) else {
      Issue.record("expected commit target")
      return
    }

    let diff = GitService.diff(
      repoRoot: repo.path,
      mode: target.mode,
      baseRef: target.baseRef,
      headRef: target.headRef,
      mergeBaseSha: target.mergeBaseSha
    )

    #expect(diff.contains("committed"))
    #expect(!diff.contains("working"))
  }

  private func makeRepo() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
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

    #expect(
      process.terminationStatus == 0, "git \(args.joined(separator: " ")) failed: \(stderrString)")
    return stdoutString
  }
}
