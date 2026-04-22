import Foundation

struct WorkspaceReviewSummaryDraft: Codable, Equatable, Sendable {
  var title: String
  var summary: String
  var testing: String
  var risks: String

  static let empty = Self(title: "", summary: "", testing: "", risks: "")

  var isEmpty: Bool {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && testing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && risks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var renderedSummary: String? {
    let normalized = normalized()
    guard !normalized.isEmpty else { return nil }

    var sections: [String] = []
    if !normalized.title.isEmpty {
      sections.append("Title: \(normalized.title)")
    }
    if !normalized.summary.isEmpty {
      sections.append("Summary:\n\(normalized.summary)")
    }
    if !normalized.testing.isEmpty {
      sections.append("Testing:\n\(normalized.testing)")
    }
    if !normalized.risks.isEmpty {
      sections.append("Risks:\n\(normalized.risks)")
    }
    return sections.joined(separator: "\n\n")
  }

  func normalized() -> Self {
    Self(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
      testing: testing.trimmingCharacters(in: .whitespacesAndNewlines),
      risks: risks.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}

struct WorkspaceReviewPreparation: Equatable, Sendable {
  let worktreePath: String
  var draft: WorkspaceReviewSummaryDraft
  var selectedAgentTabID: UUID?

  func normalized() -> Self {
    Self(
      worktreePath: worktreePath,
      draft: draft.normalized(),
      selectedAgentTabID: selectedAgentTabID
    )
  }
}

struct PendingWorkspaceAgentControlRequest: Equatable, Sendable {
  let request: WorkspaceAgentControlRequest
  let worktreePath: String
  let responseFilePath: String
  let sourceTabID: UUID?
}

enum WorkspaceAgentControlAction: Equatable, Sendable {
  case reviewSummary
  case finalize(WorktreeFinalizeAction)

  fileprivate var responseKind: String {
    switch self {
    case .reviewSummary:
      "review_summary"
    case .finalize:
      "finalize"
    }
  }
}

struct WorkspaceAgentControlRequest: Identifiable, Equatable, Sendable {
  let id: UUID
  let worktreePath: String
  let action: WorkspaceAgentControlAction
  let prompt: String

  init(
    id: UUID = UUID(),
    worktreePath: String,
    action: WorkspaceAgentControlAction,
    prompt: String
  ) {
    self.id = id
    self.worktreePath = worktreePath
    self.action = action
    self.prompt = prompt
  }

  func promptWithResponseContract(responseFilePath: String) throws -> String {
    let successResponse = try renderExampleResponse(
      status: .success,
      message: successMessageTemplate,
      responseFilePath: responseFilePath
    )
    let failedResponse = try renderExampleResponse(
      status: .failed,
      message: failureMessageTemplate,
      responseFilePath: responseFilePath
    )

    return """
      \(prompt)

      Structured response contract:
      1. When you finish, write one JSON object to this exact path:
         \(responseFilePath)
      2. Do not wrap the JSON in Markdown fences.
      3. Only report `status: "success"` after you have completed the task.
      4. Report `status: "failed"` if you are blocked or cannot complete the task.

      Success example:
      \(successResponse)

      Failure example:
      \(failedResponse)
      """
  }

  static func reviewSummary(
    repoRoot: String,
    worktreePath: String,
    branchName: String,
    baseRef: String,
    compareURL: String?
  ) -> Self {
    let compareSection =
      if let compareURL, !compareURL.isEmpty {
        "\nSuggested compare URL: \(compareURL)"
      } else {
        ""
      }

    let prompt = """
      You are preparing a review summary for Argon.

      Repository: \(repoRoot)
      Worktree: \(worktreePath)
      Feature branch: \(branchName)
      Base branch: \(baseRef)\(compareSection)

      Please inspect the current worktree diff and draft a concise review summary
      using exactly these sections:

      Title:
      <one line>

      Summary:
      <intent and implementation details>

      Testing:
      <tests run or validation performed>

      Risks:
      <known risks, follow-ups, or open questions>

      Keep it factual and ready for a human to edit before opening review.
      """

    return Self(
      worktreePath: worktreePath,
      action: .reviewSummary,
      prompt: prompt
    )
  }

  static func finalize(
    action: WorktreeFinalizeAction,
    repoRoot: String,
    worktreePath: String,
    branchName: String,
    baseRef: String,
    compareURL: String?
  ) -> Self {
    Self(
      worktreePath: worktreePath,
      action: .finalize(action),
      prompt: action.prompt(
        repoRoot: repoRoot,
        worktreePath: worktreePath,
        branchName: branchName,
        baseRef: baseRef,
        compareURL: compareURL
      )
    )
  }

  private var successMessageTemplate: String {
    switch action {
    case .reviewSummary:
      "Summary drafted from the current diff."
    case .finalize(let action):
      switch action {
      case .rebaseOntoBase:
        "Rebased the worktree onto the base branch."
      case .fastForwardToBase:
        "Fast-forwarded the base branch to the worktree."
      case .mergeCommitToBase:
        "Merged the worktree into the base branch."
      case .rebaseAndMergeToBase:
        "Rebased the worktree and landed it on the base branch."
      case .squashAndMergeToBase:
        "Squashed the worktree and landed it on the base branch."
      case .openPullRequest:
        "Opened the pull request."
      }
    }
  }

  private var failureMessageTemplate: String {
    switch action {
    case .reviewSummary:
      "Could not draft the review summary."
    case .finalize(let action):
      "Could not \(action.title) for this worktree."
    }
  }

  private func renderExampleResponse(
    status: WorkspaceAgentControlStatus,
    message: String,
    responseFilePath: String
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let response: WorkspaceAgentControlResponse
    switch action {
    case .reviewSummary:
      response = .reviewSummary(
        requestID: id,
        status: status,
        message: message,
        draft: status == .success
          ? WorkspaceReviewSummaryDraft(
            title: "One-line summary",
            summary: "Explain the intent and implementation details here.",
            testing: "List the validation you ran.",
            risks: "List follow-ups or risks."
          ) : nil
      )
    case .finalize(let action):
      response = .finalize(
        requestID: id,
        action: action,
        status: status,
        message: message,
        branchHead: status == .success ? "abc123def456" : nil,
        pullRequestURL: status == .success && action == .openPullRequest
          ? "https://github.com/example/repo/pull/42" : nil,
        followUp: status == .success
          ? "Share any extra follow-up details that the human should know."
          : nil
      )
    }

    let data = try encoder.encode(response)
    let json = String(decoding: data, as: UTF8.self)
    return """
      cat > '\(responseFilePath)' <<'EOF'
      \(json)
      EOF
      """
  }
}

enum WorkspaceAgentControlStatus: String, Codable, Equatable, Sendable {
  case success
  case failed
}

enum WorkspaceAgentControlResponse: Equatable, Sendable {
  case reviewSummary(
    requestID: UUID,
    status: WorkspaceAgentControlStatus,
    message: String,
    draft: WorkspaceReviewSummaryDraft?
  )
  case finalize(
    requestID: UUID,
    action: WorktreeFinalizeAction,
    status: WorkspaceAgentControlStatus,
    message: String,
    branchHead: String?,
    pullRequestURL: String?,
    followUp: String?
  )

  var requestID: UUID {
    switch self {
    case .reviewSummary(let requestID, _, _, _):
      requestID
    case .finalize(let requestID, _, _, _, _, _, _):
      requestID
    }
  }
}

extension WorkspaceAgentControlResponse: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case requestID = "request_id"
    case status
    case message
    case draft
    case action
    case branchHead = "branch_head"
    case pullRequestURL = "pull_request_url"
    case followUp = "follow_up"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)

    switch kind {
    case "review_summary":
      self = .reviewSummary(
        requestID: try container.decode(UUID.self, forKey: .requestID),
        status: try container.decode(WorkspaceAgentControlStatus.self, forKey: .status),
        message: try container.decode(String.self, forKey: .message),
        draft: try container.decodeIfPresent(WorkspaceReviewSummaryDraft.self, forKey: .draft)
      )
    case "finalize":
      let actionName = try container.decode(String.self, forKey: .action)
      guard let action = WorktreeFinalizeAction(agentControlIdentifier: actionName) else {
        throw DecodingError.dataCorruptedError(
          forKey: .action,
          in: container,
          debugDescription: "Unknown finalize action \(actionName)"
        )
      }
      self = .finalize(
        requestID: try container.decode(UUID.self, forKey: .requestID),
        action: action,
        status: try container.decode(WorkspaceAgentControlStatus.self, forKey: .status),
        message: try container.decode(String.self, forKey: .message),
        branchHead: try container.decodeIfPresent(String.self, forKey: .branchHead),
        pullRequestURL: try container.decodeIfPresent(String.self, forKey: .pullRequestURL),
        followUp: try container.decodeIfPresent(String.self, forKey: .followUp)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Unknown agent control response kind \(kind)"
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .reviewSummary(let requestID, let status, let message, let draft):
      try container.encode("review_summary", forKey: .kind)
      try container.encode(requestID, forKey: .requestID)
      try container.encode(status, forKey: .status)
      try container.encode(message, forKey: .message)
      try container.encodeIfPresent(draft, forKey: .draft)
    case .finalize(
      let requestID,
      let action,
      let status,
      let message,
      let branchHead,
      let pullRequestURL,
      let followUp
    ):
      try container.encode("finalize", forKey: .kind)
      try container.encode(requestID, forKey: .requestID)
      try container.encode(action.agentControlIdentifier, forKey: .action)
      try container.encode(status, forKey: .status)
      try container.encode(message, forKey: .message)
      try container.encodeIfPresent(branchHead, forKey: .branchHead)
      try container.encodeIfPresent(pullRequestURL, forKey: .pullRequestURL)
      try container.encodeIfPresent(followUp, forKey: .followUp)
    }
  }
}

extension WorktreeFinalizeAction {
  fileprivate var agentControlIdentifier: String {
    switch self {
    case .rebaseOntoBase:
      "rebase_onto_base"
    case .fastForwardToBase:
      "fast_forward_to_base"
    case .mergeCommitToBase:
      "merge_commit_to_base"
    case .rebaseAndMergeToBase:
      "rebase_and_merge_to_base"
    case .squashAndMergeToBase:
      "squash_and_merge_to_base"
    case .openPullRequest:
      "open_pull_request"
    }
  }

  fileprivate init?(agentControlIdentifier: String) {
    switch agentControlIdentifier {
    case "rebase_onto_base":
      self = .rebaseOntoBase
    case "fast_forward_to_base":
      self = .fastForwardToBase
    case "merge_commit_to_base":
      self = .mergeCommitToBase
    case "rebase_and_merge_to_base":
      self = .rebaseAndMergeToBase
    case "squash_and_merge_to_base":
      self = .squashAndMergeToBase
    case "open_pull_request":
      self = .openPullRequest
    default:
      return nil
    }
  }
}
