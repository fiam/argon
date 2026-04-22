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

enum WorkspaceAgentControlAction: Equatable, Sendable {
  case reviewSummary
  case finalize(WorktreeFinalizeAction)
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
}
