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

  @Test("review session mutations use FFI")
  func reviewSessionMutationsUseFFI() throws {
    let fixture = FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-review-session-\(UUID().uuidString)")
    let repo = fixture.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    let sessionsDirectory = SessionLoader.sessionsDirectory(repoRoot: repo.path)
    defer {
      try? FileManager.default.removeItem(atPath: sessionsDirectory)
      try? FileManager.default.removeItem(at: fixture)
    }

    let target = ResolvedTarget(
      mode: .branch,
      baseRef: "main",
      headRef: "feature/topic",
      mergeBaseSha: "abc123"
    )
    let reviewTarget = try ArgonLib.createSession(
      repoRoot: repo.path,
      target: target,
      changeSummary: "Session summary"
    )
    var session = try SessionLoader.loadSession(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot
    )
    #expect(session.mode == .branch)
    #expect(session.changeSummary == "Session summary")

    let agentPrompt = try ArgonLib.agentPrompt(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot,
      cliCommand: "argon-test"
    )
    #expect(agentPrompt.contains("Execution contract:"))
    #expect(agentPrompt.contains("argon-test --repo"))

    let reviewerPrompt = try ArgonLib.reviewerPrompt(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot,
      reviewerName: "Frost",
      cliCommand: "argon-test"
    )
    #expect(reviewerPrompt.contains("You are reviewer Frost"))
    #expect(reviewerPrompt.contains("reviewer decide"))

    try ArgonLib.addDraftComment(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot,
      message: "Fix this",
      filePath: "README.md",
      lineNew: 1
    )
    var drafts = try SessionLoader.loadDraftReview(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot
    )
    #expect(drafts.count == 1)
    let draftId = try #require(drafts.first?.id.uuidString)

    try ArgonLib.deleteDraftComment(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot,
      draftId: draftId
    )
    drafts = try SessionLoader.loadDraftReview(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot
    )
    #expect(drafts.isEmpty)

    try ArgonLib.addDraftComment(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot,
      message: "Needs changes"
    )
    try ArgonLib.submitReview(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot,
      outcome: ReviewOutcome.changesRequested.rawValue,
      summary: "Please revise"
    )
    session = try SessionLoader.loadSession(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot
    )
    #expect(session.threads.count == 1)
    #expect(session.decision?.outcome == .changesRequested)

    let threadId = try #require(session.threads.first?.id.uuidString)
    try ArgonLib.resolveThread(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot,
      threadId: threadId
    )
    session = try SessionLoader.loadSession(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot
    )
    #expect(session.threads.first?.state == .resolved)

    try ArgonLib.updateSessionTarget(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot,
      mode: ReviewMode.uncommitted.rawValue,
      baseRef: "HEAD",
      headRef: "WORKTREE",
      mergeBaseSha: "def456"
    )
    session = try SessionLoader.loadSession(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot
    )
    #expect(session.mode == .uncommitted)
    #expect(session.baseRef == "HEAD")
    #expect(session.headRef == "WORKTREE")
    #expect(session.mergeBaseSha == "def456")
    #expect(session.threads.isEmpty)

    try ArgonLib.closeSession(sessionId: reviewTarget.sessionId, repoRoot: reviewTarget.repoRoot)
    session = try SessionLoader.loadSession(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot
    )
    #expect(session.status == .closed)
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
