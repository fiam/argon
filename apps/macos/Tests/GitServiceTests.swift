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

  @Test("autoDetectTarget uses uncommitted mode for detached HEAD")
  func autoDetectTargetUsesUncommittedModeForDetachedHead() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])

    let expectedHead = try git(repo, ["rev-parse", "HEAD"]).trimmingCharacters(
      in: .whitespacesAndNewlines)

    try git(repo, ["checkout", "--detach", "HEAD"])

    let target = GitService.autoDetectTarget(repoRoot: repo.path)

    #expect(target?.mode == .uncommitted)
    #expect(target?.baseRef == "HEAD")
    #expect(target?.headRef == "WORKTREE")
    #expect(target?.mergeBaseSha == expectedHead)
  }

  @Test("uncommitted diff includes non-ignored untracked files")
  func uncommittedDiffIncludesNonIgnoredUntrackedFiles() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])

    try "ignored.txt\n".write(
      to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try git(repo, ["add", ".gitignore"])
    try git(repo, ["commit", "-m", "ignore fixture"])

    try "visible\n".write(
      to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    try "hidden\n".write(
      to: repo.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)

    let diff = GitService.diff(
      repoRoot: repo.path,
      mode: .uncommitted,
      baseRef: "HEAD",
      headRef: "WORKTREE",
      mergeBaseSha: try git(repo, ["rev-parse", "HEAD"])
    )

    #expect(diff.contains("new.txt"))
    #expect(diff.contains("visible"))
    #expect(!diff.contains("ignored.txt"))
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
    #expect(target.showsLinkedWorktreeWarning == true)
  }

  @Test("branchTopology reports ahead and behind commit counts")
  func branchTopologyReportsAheadAndBehindCounts() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])

    try git(repo, ["checkout", "-b", "feature/topic"])
    try "one\nfeature 1\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "feature 1"])
    try "one\nfeature 1\nfeature 2\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "feature 2"])

    try git(repo, ["checkout", "main"])
    try "one\nmain 1\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "main 1"])

    let topology = GitService.branchTopology(
      repoRoot: repo.path,
      baseRef: "main",
      headRef: "feature/topic"
    )

    #expect(topology?.aheadCount == 2)
    #expect(topology?.behindCount == 1)
    #expect(topology?.needsRebase == true)
    #expect(topology?.canFastForwardBase == false)
  }

  @Test("defaultWorktreeStartPoint prefers local branch for a remote base")
  func defaultWorktreeStartPointPrefersLocalBranchForRemoteBase() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let remote = fixture.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    try git(remote, ["init", "--bare"])

    let repo = fixture.appendingPathComponent("repo")
    try git(fixture, ["clone", remote.path, repo.path])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])
    try git(repo, ["push", "-u", "origin", "main:main"])

    try git(repo, ["checkout", "-b", "feature/window"])
    try "one\nfeature\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "feature"])

    try git(repo, ["checkout", "main"])
    try "one\nmain 1\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "main 1"])
    try "one\nmain 1\nmain 2\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "main 2"])

    let topology = GitService.branchTopology(
      repoRoot: repo.path,
      baseRef: "origin/main",
      headRef: "feature/window"
    )

    #expect(topology?.aheadCount == 1)
    #expect(topology?.behindCount == 0)
    #expect(
      GitService.defaultWorktreeStartPoint(
        repoRoot: repo.path,
        baseRef: "origin/main"
      ) == "main"
    )
    #expect(
      GitService.defaultWorktreeStartPoint(
        repoRoot: repo.path,
        baseRef: nil
      ) == "main"
    )
    #expect(
      GitService.branchTopology(
        repoRoot: repo.path,
        baseRef: "main",
        headRef: "feature/window"
      )?.behindCount == 2
    )
    #expect(
      GitService.defaultWorktreeStartPoint(
        repoRoot: repo.path,
        baseRef: "origin/missing"
      ) == "origin/missing"
    )
  }

  @Test("branchTopology keeps local and remote bases distinct")
  func branchTopologyKeepsLocalAndRemoteBasesDistinct() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let remote = fixture.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    try git(remote, ["init", "--bare"])

    let repo = fixture.appendingPathComponent("repo")
    try git(fixture, ["clone", remote.path, repo.path])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])
    try git(repo, ["push", "-u", "origin", "main:main"])

    try git(repo, ["checkout", "-b", "feature/window"])
    try "one\nfeature\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "feature"])

    try git(repo, ["checkout", "main"])
    try "one\nmain\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "main"])

    let remoteTopology = GitService.branchTopology(
      repoRoot: repo.path,
      baseRef: "origin/main",
      headRef: "feature/window"
    )
    let localTopology = GitService.branchTopology(
      repoRoot: repo.path,
      baseRef: "main",
      headRef: "feature/window"
    )

    #expect(remoteTopology?.aheadCount == 1)
    #expect(remoteTopology?.behindCount == 0)
    #expect(localTopology?.aheadCount == 1)
    #expect(localTopology?.behindCount == 1)
  }

  @Test("branchTopology display label describes divergence")
  func branchTopologyDisplayLabelDescribesDivergence() {
    #expect(BranchTopology(aheadCount: 0, behindCount: 0).displayLabel == nil)
    #expect(BranchTopology(aheadCount: 1, behindCount: 0).displayLabel == "1 commit ahead")
    #expect(BranchTopology(aheadCount: 0, behindCount: 2).displayLabel == "2 commits behind")
    #expect(
      BranchTopology(aheadCount: 3, behindCount: 1).displayLabel
        == "3 commits ahead, 1 commit behind"
    )
  }

  @Test("inferBaseRef prefers the nearest parent worktree branch")
  func inferBaseRefPrefersNearestParentWorktreeBranch() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let repo = fixture.appendingPathComponent("repo")
    let parent = fixture.appendingPathComponent("parent")
    let child = fixture.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "base\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])

    try git(repo, ["worktree", "add", "-b", "parent/topic", parent.path, "HEAD"])
    try "base\nparent\n".write(
      to: parent.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(parent, ["commit", "-am", "parent"])

    try git(repo, ["worktree", "add", "-b", "child/topic", child.path, "parent/topic"])
    try "base\nparent\nchild\n".write(
      to: child.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(child, ["commit", "-am", "child"])

    #expect(GitService.inferBaseRef(repoRoot: child.path) == "parent/topic")
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
    let upstream = try git(
      worktree,
      [
        "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}",
      ]
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let discovered = try GitService.discoverWorktrees(
      repoRoot: repo.path,
      repoCommonDir: repo.appendingPathComponent(".git").path
    )

    #expect(branchName == "feature/new-worktree")
    #expect(upstream == "main")
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

  @Test("hasUncommittedChanges reports clean and dirty worktrees")
  func hasUncommittedChangesReportsCleanAndDirtyWorktrees() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])

    #expect(GitService.hasUncommittedChanges(repoRoot: repo.path) == false)

    try "one\ntwo\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    #expect(GitService.hasUncommittedChanges(repoRoot: repo.path) == true)
  }

  @Test("removeWorktree removes a clean linked worktree")
  func removeWorktreeRemovesACleanLinkedWorktree() throws {
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
    try git(repo, ["worktree", "add", "-b", "feature/remove-clean", worktree.path, "HEAD"])

    try GitService.removeWorktree(repoRoot: repo.path, path: worktree.path)

    let discovered = try GitService.discoverWorktrees(
      repoRoot: repo.path,
      repoCommonDir: repo.appendingPathComponent(".git").path
    )

    #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
    #expect(discovered.count == 1)
    #expect(discovered.first?.path == repo.path)
  }

  @Test("removeWorktree requires force for dirty linked worktrees")
  func removeWorktreeRequiresForceForDirtyLinkedWorktrees() throws {
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

    let worktree = fixture.appendingPathComponent("feature-dirty-worktree")
    try git(repo, ["worktree", "add", "-b", "feature/remove-dirty", worktree.path, "HEAD"])
    try "one\ndirty\n".write(
      to: worktree.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )

    #expect(GitService.hasUncommittedChanges(repoRoot: worktree.path) == true)
    #expect(throws: GitService.GitError.self) {
      try GitService.removeWorktree(repoRoot: repo.path, path: worktree.path)
    }

    try GitService.removeWorktree(repoRoot: repo.path, path: worktree.path, force: true)

    #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
  }

  @Test("removeWorktree removes a clean linked worktree with initialized submodules")
  func removeWorktreeRemovesCleanLinkedWorktreeWithInitializedSubmodules() throws {
    let fixture = try makeSubmoduleWorktreeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(GitService.hasInitializedSubmodules(repoRoot: fixture.worktree.path))
    #expect(GitService.hasUncommittedChanges(repoRoot: fixture.worktree.path) == false)

    try GitService.removeWorktree(repoRoot: fixture.repo.path, path: fixture.worktree.path)

    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path) == false)
  }

  @Test("removeWorktree requires force for dirty initialized submodules")
  func removeWorktreeRequiresForceForDirtyInitializedSubmodules() throws {
    let fixture = try makeSubmoduleWorktreeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try "sub one\ndirty\n".write(
      to: fixture.worktree.appendingPathComponent("vendor/sub/sub.txt"),
      atomically: true,
      encoding: .utf8
    )

    #expect(GitService.hasInitializedSubmodules(repoRoot: fixture.worktree.path))
    #expect(GitService.hasUncommittedChanges(repoRoot: fixture.worktree.path))
    #expect(throws: GitService.GitError.self) {
      try GitService.removeWorktree(repoRoot: fixture.repo.path, path: fixture.worktree.path)
    }

    try GitService.removeWorktree(
      repoRoot: fixture.repo.path, path: fixture.worktree.path, force: true)

    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path) == false)
  }

  @Test("branchHasUniqueCommits distinguishes empty and non-empty branches")
  func branchHasUniqueCommitsDistinguishesEmptyAndNonEmptyBranches() throws {
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

    try git(repo, ["branch", "feature/empty"])
    #expect(
      GitService.branchHasUniqueCommits(
        repoRoot: repo.path,
        branchName: "feature/empty",
        baseRef: "main"
      ) == false
    )

    try git(repo, ["checkout", "-b", "feature/non-empty"])
    try "one\ntwo\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "feature"])
    try git(repo, ["checkout", "main"])

    #expect(
      GitService.branchHasUniqueCommits(
        repoRoot: repo.path,
        branchName: "feature/non-empty",
        baseRef: "main"
      ) == true
    )
  }

  @Test("branch safety checks treat cherry-picked commits as integrated")
  func branchSafetyChecksTreatCherryPickedCommitsAsIntegrated() throws {
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

    try git(repo, ["checkout", "-b", "feature/cherry-picked"])
    try "one\ntwo\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "feature"])
    let featureCommit = try git(repo, ["rev-parse", "HEAD"])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    try git(repo, ["checkout", "main"])
    try "base\n".write(
      to: repo.appendingPathComponent("base.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["add", "base.txt"])
    try git(repo, ["commit", "-m", "base change"])
    try git(repo, ["cherry-pick", featureCommit])

    #expect(
      GitService.branchHasUniqueCommits(
        repoRoot: repo.path,
        branchName: "feature/cherry-picked",
        baseRef: "main"
      ) == false
    )
    #expect(
      GitService.branchHasUnpushedCommits(
        repoRoot: repo.path,
        branchName: "feature/cherry-picked",
        baseRef: "main"
      ) == false
    )
    #expect(
      GitService.branchRequiresForceDelete(
        repoRoot: repo.path,
        branchName: "feature/cherry-picked",
        baseRef: "main"
      )
    )
    #expect(throws: GitService.GitError.self) {
      try GitService.deleteBranch(
        repoRoot: repo.path,
        branchName: "feature/cherry-picked"
      )
    }

    try GitService.deleteBranch(
      repoRoot: repo.path,
      branchName: "feature/cherry-picked",
      force: GitService.branchRequiresForceDelete(
        repoRoot: repo.path,
        branchName: "feature/cherry-picked",
        baseRef: "main"
      )
    )
    #expect(GitService.resolveRef(repoRoot: repo.path, ref: "feature/cherry-picked") == nil)
  }

  @Test("branchHasUnpushedCommits detects branch commits missing from remotes and base")
  func branchHasUnpushedCommitsDetectsBranchCommitsMissingFromRemotesAndBase() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let remote = fixture.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    try git(remote, ["init", "--bare"])

    let repo = fixture.appendingPathComponent("repo")
    try git(fixture, ["clone", remote.path, repo.path])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])
    try git(repo, ["push", "-u", "origin", "main"])

    try git(repo, ["checkout", "-b", "feature/unpushed"])
    try "one\ntwo\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "feature"])

    #expect(
      GitService.branchHasUnpushedCommits(
        repoRoot: repo.path,
        branchName: "feature/unpushed",
        baseRef: "main"
      )
    )

    try git(repo, ["push", "-u", "origin", "feature/unpushed"])

    #expect(
      GitService.branchHasUnpushedCommits(
        repoRoot: repo.path,
        branchName: "feature/unpushed",
        baseRef: "main"
      ) == false
    )
  }

  @Test("submodulesWithUnpushedCommits detects local submodule commits")
  func submodulesWithUnpushedCommitsDetectsLocalSubmoduleCommits() throws {
    let fixture = try makeSubmoduleWorktreeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let submodule = fixture.worktree.appendingPathComponent("vendor/sub")
    try git(submodule, ["config", "user.name", "Argon Test"])
    try git(submodule, ["config", "user.email", "argon-test@example.com"])
    try "sub one\nlocal\n".write(
      to: submodule.appendingPathComponent("sub.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(submodule, ["commit", "-am", "local submodule commit"])
    try git(fixture.worktree, ["add", "vendor/sub"])
    try git(fixture.worktree, ["commit", "-m", "Update submodule pointer"])

    #expect(GitService.hasUncommittedChanges(repoRoot: fixture.worktree.path) == false)
    #expect(
      GitService.submodulesWithUnpushedCommits(repoRoot: fixture.worktree.path)
        == [SubmoduleUnpushedCommits(path: "vendor/sub", commitCount: 1)]
    )
  }

  @Test("preferredBranchDeletionBaseRef prefers the current local branch over origin")
  func preferredBranchDeletionBaseRefPrefersCurrentLocalBranchOverOrigin() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let remote = fixture.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    try git(remote, ["init", "--bare"])

    let repo = fixture.appendingPathComponent("repo")
    try git(fixture, ["clone", remote.path, repo.path])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])

    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])
    try git(repo, ["push", "-u", "origin", "main"])
    try git(repo, ["fetch", "origin"])

    try "one\ntwo\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "local-only"])
    try git(repo, ["branch", "feature/same-tip"])

    #expect(GitService.inferBaseRef(repoRoot: repo.path) != "main")
    #expect(
      GitService.preferredBranchDeletionBaseRef(
        repoRoot: repo.path,
        branchName: "feature/same-tip"
      ) == "main"
    )
    #expect(
      GitService.branchHasUniqueCommits(
        repoRoot: repo.path,
        branchName: "feature/same-tip",
        baseRef: GitService.preferredBranchDeletionBaseRef(
          repoRoot: repo.path,
          branchName: "feature/same-tip"
        )
      ) == false
    )
  }

  @Test("deleteBranch deletes merged branches and force deletes unmerged branches")
  func deleteBranchDeletesMergedBranchesAndForceDeletesUnmergedBranches() throws {
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

    try git(repo, ["branch", "feature/merged"])
    try GitService.deleteBranch(repoRoot: repo.path, branchName: "feature/merged")

    let mergedBranchRef = GitService.resolveRef(repoRoot: repo.path, ref: "feature/merged")
    #expect(mergedBranchRef == nil)

    try git(repo, ["checkout", "-b", "feature/unmerged"])
    try "one\nthree\n".write(
      to: repo.appendingPathComponent("a.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(repo, ["commit", "-am", "unmerged"])
    try git(repo, ["checkout", "main"])

    #expect(throws: GitService.GitError.self) {
      try GitService.deleteBranch(repoRoot: repo.path, branchName: "feature/unmerged")
    }

    try GitService.deleteBranch(repoRoot: repo.path, branchName: "feature/unmerged", force: true)
    let unmergedBranchRef = GitService.resolveRef(repoRoot: repo.path, ref: "feature/unmerged")
    #expect(unmergedBranchRef == nil)
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

  @Test("pullRequestURL prefers an existing GitHub pull request when gh returns one")
  func pullRequestURLPrefersExistingGitHubPullRequest() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["remote", "add", "origin", "git@github.com:openai/argon-native.git"])

    let previousRunner = GitService.commandRunner
    defer { GitService.commandRunner = previousRunner }
    GitService.commandRunner = { executable, arguments, currentDirectoryPath, environment in
      #expect(executable == "/usr/bin/env")
      #expect(
        arguments == [
          "gh", "pr", "view",
          "--json", "url",
          "--head", "feature/workspace-window",
          "--base", "main",
        ])
      #expect(currentDirectoryPath == repo.path)
      #expect(environment?["GH_PROMPT_DISABLED"] == "1")
      return CommandResult(
        terminationStatus: 0,
        stdout: #"{"url":"https://github.com/openai/argon-native/pull/42"}"#,
        stderr: ""
      )
    }

    let url = GitService.pullRequestURL(
      repoRoot: repo.path,
      mode: .branch,
      baseRef: "origin/main",
      headRef: "feature/workspace-window"
    )

    #expect(url == "https://github.com/openai/argon-native/pull/42")
  }

  @Test("pullRequestURL falls back to compare URL when gh cannot resolve a PR")
  func pullRequestURLFallsBackToCompareURLWhenGhCannotResolvePR() throws {
    let repo = try makeRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    try git(repo, ["init"])
    try git(repo, ["remote", "add", "origin", "git@github.com:openai/argon-native.git"])

    let previousRunner = GitService.commandRunner
    defer { GitService.commandRunner = previousRunner }
    GitService.commandRunner = { _, _, _, _ in
      CommandResult(terminationStatus: 1, stdout: "", stderr: "not found")
    }

    let url = GitService.pullRequestURL(
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

  private func makeSubmoduleWorktreeFixture() throws -> SubmoduleWorktreeFixture {
    let fixture = try makeFixtureDirectory()
    let submoduleSource = fixture.appendingPathComponent("submodule-source")
    let repo = fixture.appendingPathComponent("repo")
    let worktree = fixture.appendingPathComponent("feature-submodule-worktree")

    try FileManager.default.createDirectory(at: submoduleSource, withIntermediateDirectories: true)
    try git(submoduleSource, ["init"])
    try git(submoduleSource, ["config", "user.name", "Argon Test"])
    try git(submoduleSource, ["config", "user.email", "argon-test@example.com"])
    try "sub one\n".write(
      to: submoduleSource.appendingPathComponent("sub.txt"),
      atomically: true,
      encoding: .utf8
    )
    try git(submoduleSource, ["add", "sub.txt"])
    try git(submoduleSource, ["commit", "-m", "submodule init"])

    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try git(repo, ["init"])
    try git(repo, ["config", "user.name", "Argon Test"])
    try git(repo, ["config", "user.email", "argon-test@example.com"])
    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git(repo, ["add", "a.txt"])
    try git(repo, ["commit", "-m", "init"])
    try git(repo, ["branch", "-M", "main"])
    try git(
      repo,
      ["-c", "protocol.file.allow=always", "submodule", "add", submoduleSource.path, "vendor/sub"])
    try git(repo, ["commit", "-am", "add submodule"])
    try git(repo, ["worktree", "add", "-b", "feature/submodule", worktree.path, "HEAD"])
    try git(
      worktree,
      ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"])

    return SubmoduleWorktreeFixture(root: fixture, repo: repo, worktree: worktree)
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

private struct SubmoduleWorktreeFixture {
  let root: URL
  let repo: URL
  let worktree: URL
}
