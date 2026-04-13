import Foundation
import Testing

@testable import Argon

@Suite("SessionLoader")
struct SessionLoaderTests {

  @Test("repo storage key is deterministic")
  func repoStorageKeyIsDeterministic() {
    // The FNV-1a hash should produce the same key for the same path
    let key1 = testRepoStorageKey("/tmp/test-repo")
    let key2 = testRepoStorageKey("/tmp/test-repo")
    #expect(key1 == key2)
  }

  @Test("repo storage key differs for different paths")
  func repoStorageKeyDiffers() {
    let key1 = testRepoStorageKey("/tmp/repo-a")
    let key2 = testRepoStorageKey("/tmp/repo-b")
    #expect(key1 != key2)
  }

  @Test("repo storage key sanitizes name")
  func repoStorageKeySanitizes() {
    let key = testRepoStorageKey("/tmp/My Project (2)")
    // Should only contain lowercase alphanumeric, hyphens, underscores
    let name = key.split(separator: "-").dropLast().joined(separator: "-")
    let valid = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    #expect(valid)
    #expect(name == name.lowercased())
  }

  @Test("latest review snapshots choose the newest session per repo root")
  func latestReviewSnapshotsChooseNewestSessionPerRepoRoot() throws {
    let storageRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    defer {
      unsetenv("ARGON_HOME")
      try? FileManager.default.removeItem(at: storageRoot)
    }

    setenv("ARGON_HOME", storageRoot.path, 1)

    let repoRoot = "/tmp/repo-window"
    let sessionsDirectory =
      storageRoot
      .appendingPathComponent("sessions")
      .appendingPathComponent("fixture-repo")
    try FileManager.default.createDirectory(
      at: sessionsDirectory, withIntermediateDirectories: true)

    try write(
      session: makeSession(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        repoRoot: repoRoot,
        status: .awaitingReviewer,
        updatedAt: Date(timeIntervalSince1970: 10)
      ),
      to: sessionsDirectory.appendingPathComponent("older.json")
    )
    try write(
      session: makeSession(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        repoRoot: repoRoot,
        status: .awaitingAgent,
        updatedAt: Date(timeIntervalSince1970: 20)
      ),
      to: sessionsDirectory.appendingPathComponent("newer.json")
    )

    let snapshots = SessionLoader.latestReviewSnapshots(forRepoRoots: [repoRoot])

    #expect(snapshots.count == 1)
    #expect(
      snapshots[repoRoot]?.sessionId == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    #expect(snapshots[repoRoot]?.status == .awaitingAgent)
  }

  // Mirror the SessionLoader's private methods for testing
  private func testRepoStorageKey(_ repoRoot: String) -> String {
    let url = URL(fileURLWithPath: repoRoot)
    let resolved = url.standardizedFileURL.path
    let name = URL(fileURLWithPath: resolved).lastPathComponent
    let sanitized = sanitizeRepoName(name)
    let repoName = sanitized.isEmpty ? "repo" : sanitized
    let hash = fnv1a64(Array(resolved.utf8))
    return "\(repoName)-\(String(format: "%016llx", hash))"
  }

  private func sanitizeRepoName(_ name: String) -> String {
    String(
      name.compactMap { ch -> Character? in
        let lower = ch.lowercased().first!
        if lower.isASCII && (lower.isLetter || lower.isNumber || lower == "-" || lower == "_") {
          return lower
        }
        return nil
      })
  }

  private func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return hash
  }

  private func makeSession(
    id: UUID,
    repoRoot: String,
    status: SessionStatus,
    updatedAt: Date
  ) -> ReviewSession {
    ReviewSession(
      id: id,
      repoRoot: repoRoot,
      mode: .branch,
      baseRef: "origin/main",
      headRef: "feature/workspace",
      mergeBaseSha: "abc123",
      changeSummary: "Add workspace tabs",
      status: status,
      threads: [],
      decision: nil,
      agentLastSeenAt: nil,
      createdAt: updatedAt,
      updatedAt: updatedAt
    )
  }

  private func write(session: ReviewSession, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(session)
    try data.write(to: url)
  }
}
