import Foundation

enum SessionStatus: String, Codable {
  case awaitingReviewer = "awaiting_reviewer"
  case awaitingAgent = "awaiting_agent"
  case approved
  case closed
}

enum ReviewMode: String, Codable {
  case branch
  case commit
  case uncommitted
}

enum ThreadState: String, Codable {
  case open
  case addressed
  case resolved
}

enum CommentAuthor: String, Codable {
  case reviewer
  case agent
}

enum CommentKind: String, Codable {
  case line
  case global
}

enum ReviewOutcome: String, Codable {
  case approved
  case changesRequested = "changes_requested"
  case commented
}

struct CommentAnchor: Codable {
  let filePath: String?
  let lineNew: UInt32?
  let lineOld: UInt32?

  enum CodingKeys: String, CodingKey {
    case filePath = "file_path"
    case lineNew = "line_new"
    case lineOld = "line_old"
  }
}

struct ReviewComment: Codable, Identifiable {
  let id: UUID
  let threadId: UUID
  let author: CommentAuthor
  let authorName: String?
  let kind: CommentKind
  let anchor: CommentAnchor
  let body: String
  let createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case threadId = "thread_id"
    case author
    case authorName = "author_name"
    case kind, anchor, body
    case createdAt = "created_at"
  }
}

struct ReviewThread: Codable, Identifiable {
  let id: UUID
  let state: ThreadState
  let agentAcknowledgedAt: Date?
  let comments: [ReviewComment]

  enum CodingKeys: String, CodingKey {
    case id, state
    case agentAcknowledgedAt = "agent_acknowledged_at"
    case comments
  }
}

struct ReviewDecision: Codable {
  let outcome: ReviewOutcome
  let summary: String?
  let createdAt: Date

  enum CodingKeys: String, CodingKey {
    case outcome, summary
    case createdAt = "created_at"
  }
}

struct ReviewSession: Codable, Identifiable {
  let id: UUID
  let repoRoot: String
  let mode: ReviewMode
  let baseRef: String
  let headRef: String
  let mergeBaseSha: String
  let changeSummary: String?
  let status: SessionStatus
  let threads: [ReviewThread]
  let decision: ReviewDecision?
  let agentLastSeenAt: Date?
  let createdAt: Date
  let updatedAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case repoRoot = "repo_root"
    case mode
    case baseRef = "base_ref"
    case headRef = "head_ref"
    case mergeBaseSha = "merge_base_sha"
    case changeSummary = "change_summary"
    case status, threads, decision
    case agentLastSeenAt = "agent_last_seen_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}
