import Foundation
import Testing

@testable import Argon

@Suite("Session Model")
struct SessionModelTests {

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  @Test("ReviewSession JSON round-trips correctly")
  func reviewSessionRoundTrips() throws {
    let json = """
      {
        "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        "repo_root": "/tmp/test-repo",
        "mode": "branch",
        "base_ref": "origin/main",
        "head_ref": "feature-branch",
        "merge_base_sha": "abc123def456",
        "change_summary": "Added new feature",
        "status": "awaiting_reviewer",
        "threads": [],
        "decision": null,
        "agent_last_seen_at": null,
        "created_at": "2026-01-15T10:30:00Z",
        "updated_at": "2026-01-15T11:00:00Z"
      }
      """

    let session = try Self.makeDecoder().decode(ReviewSession.self, from: Data(json.utf8))

    #expect(session.id == UUID(uuidString: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"))
    #expect(session.repoRoot == "/tmp/test-repo")
    #expect(session.mode == .branch)
    #expect(session.baseRef == "origin/main")
    #expect(session.headRef == "feature-branch")
    #expect(session.mergeBaseSha == "abc123def456")
    #expect(session.changeSummary == "Added new feature")
    #expect(session.status == .awaitingReviewer)
    #expect(session.threads.isEmpty)
    #expect(session.decision == nil)
    #expect(session.agentLastSeenAt == nil)

    // Re-encode and decode to verify round-trip
    let encoded = try Self.makeEncoder().encode(session)
    let decoded = try Self.makeDecoder().decode(ReviewSession.self, from: encoded)
    #expect(decoded.id == session.id)
    #expect(decoded.repoRoot == session.repoRoot)
    #expect(decoded.mode == session.mode)
    #expect(decoded.baseRef == session.baseRef)
    #expect(decoded.headRef == session.headRef)
  }

  @Test("ReviewMode uncommitted deserializes correctly")
  func reviewModeUncommitted() throws {
    let json = """
      {
        "id": "11111111-2222-3333-4444-555555555555",
        "repo_root": "/tmp/repo",
        "mode": "uncommitted",
        "base_ref": "HEAD",
        "head_ref": "WORKTREE",
        "merge_base_sha": "deadbeef",
        "change_summary": null,
        "status": "awaiting_agent",
        "threads": [],
        "decision": null,
        "agent_last_seen_at": null,
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z"
      }
      """

    let session = try Self.makeDecoder().decode(ReviewSession.self, from: Data(json.utf8))
    #expect(session.mode == .uncommitted)
  }

  @Test("optional fields handle null correctly")
  func optionalFieldsHandleNull() throws {
    let json = """
      {
        "id": "11111111-2222-3333-4444-555555555555",
        "repo_root": "/tmp/repo",
        "mode": "commit",
        "base_ref": "HEAD",
        "head_ref": "WORKTREE",
        "merge_base_sha": "cafebabe",
        "change_summary": null,
        "status": "approved",
        "threads": [],
        "decision": null,
        "agent_last_seen_at": null,
        "created_at": "2026-02-01T00:00:00Z",
        "updated_at": "2026-02-01T00:00:00Z"
      }
      """

    let session = try Self.makeDecoder().decode(ReviewSession.self, from: Data(json.utf8))
    #expect(session.changeSummary == nil)
    #expect(session.decision == nil)
    #expect(session.agentLastSeenAt == nil)
  }

  @Test("DraftComment JSON round-trips correctly")
  func draftCommentRoundTrips() throws {
    let json = """
      {
        "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        "thread_id": null,
        "anchor": {
          "file_path": "src/main.rs",
          "line_new": 42,
          "line_old": null
        },
        "body": "This looks wrong",
        "created_at": "2026-03-01T12:00:00Z",
        "updated_at": "2026-03-01T12:30:00Z"
      }
      """

    let draft = try Self.makeDecoder().decode(DraftComment.self, from: Data(json.utf8))

    #expect(draft.id == UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
    #expect(draft.threadId == nil)
    #expect(draft.anchor.filePath == "src/main.rs")
    #expect(draft.anchor.lineNew == 42)
    #expect(draft.anchor.lineOld == nil)
    #expect(draft.body == "This looks wrong")

    // Round-trip
    let encoded = try Self.makeEncoder().encode(draft)
    let decoded = try Self.makeDecoder().decode(DraftComment.self, from: encoded)
    #expect(decoded.id == draft.id)
    #expect(decoded.body == draft.body)
    #expect(decoded.anchor.filePath == draft.anchor.filePath)
    #expect(decoded.anchor.lineNew == draft.anchor.lineNew)
  }

  @Test("CommentAnchor with nil fields serializes correctly")
  func commentAnchorNilFields() throws {
    let json = """
      {
        "file_path": null,
        "line_new": null,
        "line_old": null
      }
      """

    let anchor = try Self.makeDecoder().decode(CommentAnchor.self, from: Data(json.utf8))
    #expect(anchor.filePath == nil)
    #expect(anchor.lineNew == nil)
    #expect(anchor.lineOld == nil)

    // Re-encode and verify nulls survive
    let encoded = try Self.makeEncoder().encode(anchor)
    let decoded = try Self.makeDecoder().decode(CommentAnchor.self, from: encoded)
    #expect(decoded.filePath == nil)
    #expect(decoded.lineNew == nil)
    #expect(decoded.lineOld == nil)
  }
}
