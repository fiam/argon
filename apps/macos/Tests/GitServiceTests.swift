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

  @Test("context sources use working tree for uncommitted diffs")
  func contextSourcesUseWorkingTreeForUncommittedDiffs() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])

    try "one\nworking\n".write(
      to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

    let file = FileDiff(oldPath: "a.txt", newPath: "a.txt", hunks: [])
    let sources = GitService.contextSources(
      for: [file],
      repoRoot: repo.path,
      mode: .uncommitted,
      baseRef: "HEAD",
      headRef: "WORKTREE",
      mergeBaseSha: "HEAD"
    )

    #expect(sources[file.id]?.side == .new)
    #expect(sources[file.id]?.lines == ["one", "working"])
  }

  @Test("resolveWorkspaceTarget uses shared git common dir and selected worktree")
  func resolveWorkspaceTargetUsesCommonDir() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let repo = fixture.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])

    let worktree = fixture.appendingPathComponent("feature-worktree")
    try git(repo, ["worktree", "add", "-b", "feature/refocus", worktree.path, "HEAD"])

    let target = try GitService.resolveWorkspaceTarget(path: worktree.path)

    #expect(target.repoRoot == repo.path)
    #expect(target.repoCommonDir == repo.appendingPathComponent(".git").path)
    #expect(target.selectedWorktreePath == worktree.path)
  }

  @Test("discoverWorktrees returns base and linked worktrees")
  func discoverWorktreesIncludesBaseAndLinkedWorktrees() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let repo = fixture.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])

    let worktree = fixture.appendingPathComponent("feature-worktree")
    try git(repo, ["worktree", "add", "-b", "feature/refocus", worktree.path, "HEAD"])

    let discovered = try GitService.discoverWorktrees(
      repoRoot: repo.path,
      repoCommonDir: repo.appendingPathComponent(".git").path
    )

    #expect(discovered.count == 2)
    #expect(discovered.first?.path == repo.path)
    #expect(discovered.first?.isBaseWorktree == true)
    #expect(discovered.contains { $0.path == worktree.path && $0.branchName == "feature/refocus" })
  }

  @Test("createWorktree creates and discovers a new linked worktree")
  func createWorktreeCreatesAndDiscoversNewLinkedWorktree() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let repo = fixture.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])

    let worktree = fixture.appendingPathComponent("feature-worktree")
    try GitService.createWorktree(
      repoRoot: repo.path,
      branchName: "feature/new-worktree",
      path: worktree.path,
      startPoint: "HEAD"
    )

    let branchName = try git(worktree, ["branch", "--show-current"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let discovered = try GitService.discoverWorktrees(
      repoRoot: repo.path,
      repoCommonDir: repo.appendingPathComponent(".git").path
    )

    #expect(branchName == "feature/new-worktree")
    #expect(discovered.contains { $0.path == worktree.path && $0.branchName == branchName })
  }

  @Test("createWorktree creates missing parent directories")
  func createWorktreeCreatesMissingParentDirectories() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let repo = fixture.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])

    let worktree =
      fixture
      .appendingPathComponent("central-root")
      .appendingPathComponent("tmp")
      .appendingPathComponent("repo")
      .appendingPathComponent("feature-worktree")

    try GitService.createWorktree(
      repoRoot: repo.path,
      branchName: "feature/nested-worktree",
      path: worktree.path,
      startPoint: "HEAD"
    )

    #expect(FileManager.default.fileExists(atPath: worktree.path))
    #expect(FileManager.default.fileExists(atPath: worktree.deletingLastPathComponent().path))
  }

  @Test("formatDiffStat renders file rows and totals")
  func formatDiffStatRendersFileRowsAndTotals() {
    let files = [
      FileDiff(
        oldPath: "Sources/App.swift",
        newPath: "Sources/App.swift",
        hunks: [],
        addedCount: 3,
        removedCount: 1
      ),
      FileDiff(
        oldPath: "README.md",
        newPath: "README.md",
        hunks: [],
        addedCount: 2,
        removedCount: 0
      ),
    ]

    let stat = GitService.formatDiffStat(files: files)

    #expect(stat.contains("Sources/App.swift"))
    #expect(stat.contains("README.md"))
    #expect(stat.contains("2 files changed, 5 insertions(+), 1 deletions(-)"))
  }

  @Test("diffFiles returns parsed file entries for uncommitted changes")
  func diffFilesReturnsParsedFileEntriesForUncommittedChanges() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])

    try "one\nupdated\n".write(
      to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "new\n".write(
      to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

    let files = GitService.diffFiles(repoRoot: repo.path)

    #expect(files.count == 2)
    #expect(files.contains { $0.displayPath == "a.txt" && $0.addedCount == 1 })
    #expect(files.contains { $0.displayPath == "b.txt" && $0.addedCount == 1 })
  }

  @Test("pullRequestCompareURL builds a GitHub compare URL from origin")
  func pullRequestCompareURLBuildsGitHubCompareURL() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["remote", "add", "origin", "git@github.com:openai/argon-native.git"])

    let url = GitService.pullRequestCompareURL(
      repoRoot: repo.path,
      mode: .branch,
      baseRef: "origin/main",
      headRef: "feature/workspace-window"
    )

    #expect(
      url
        == "https://github.com/openai/argon-native/compare/main...feature/workspace-window?expand=1"
    )
  }

  private func makeRepo() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func makeFixtureDirectory() throws -> URL {
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
