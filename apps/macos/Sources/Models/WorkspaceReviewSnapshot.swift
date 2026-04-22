import Foundation

struct WorkspaceReviewSnapshot: Hashable, Sendable {
  let sessionId: UUID
  let mode: ReviewMode
  let baseRef: String
  let headRef: String
  let mergeBaseSha: String
  let status: SessionStatus
  let changeSummary: String?
  let decisionOutcome: ReviewOutcome?
  let decisionSummary: String?
  let updatedAt: Date
  let totalThreadCount: Int
  let unresolvedThreadCount: Int

  init(session: ReviewSession) {
    self.sessionId = session.id
    self.mode = session.mode
    self.baseRef = session.baseRef
    self.headRef = session.headRef
    self.mergeBaseSha = session.mergeBaseSha
    self.status = session.status
    self.changeSummary = session.changeSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.decisionOutcome = session.decision?.outcome
    self.decisionSummary = session.decision?.summary?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    self.updatedAt = session.updatedAt
    self.totalThreadCount = session.threads.count
    self.unresolvedThreadCount = session.threads.reduce(into: 0) { count, thread in
      if thread.state != .resolved {
        count += 1
      }
    }
  }

  var hasChangeSummary: Bool {
    changeSummary?.isEmpty == false
  }

  var hasDecisionSummary: Bool {
    decisionSummary?.isEmpty == false
  }

  func matches(target: ResolvedTarget?) -> Bool {
    guard let target else { return false }
    return mode == target.mode
      && baseRef == target.baseRef
      && headRef == target.headRef
      && mergeBaseSha == target.mergeBaseSha
  }
}
