import Foundation
import Testing

@testable import Argon

@Suite("WorkspaceAgentControl")
struct WorkspaceAgentControlTests {
  @Test("review summary response round trips")
  func reviewSummaryResponseRoundTrips() throws {
    let response = WorkspaceAgentControlResponse.reviewSummary(
      requestID: UUID(uuidString: "8170DB1F-2A39-4306-B0C0-C80AFAB0151E")!,
      status: .success,
      message: "Summary drafted from the current diff.",
      draft: WorkspaceReviewSummaryDraft(
        title: "Add summary-first review flow",
        summary: "Introduces a review preparation sheet and persists drafts.",
        testing: "make check",
        risks: "Need broader UI coverage."
      )
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(response)
    let decoded = try JSONDecoder().decode(WorkspaceAgentControlResponse.self, from: data)

    #expect(decoded == response)
  }

  @Test("finalize response round trips")
  func finalizeResponseRoundTrips() throws {
    let response = WorkspaceAgentControlResponse.finalize(
      requestID: UUID(uuidString: "5F44E59D-4AD9-4E53-A835-04BFBB6802EB")!,
      action: .openPullRequest,
      status: .success,
      message: "Opened the pull request.",
      branchHead: "abc123",
      pullRequestURL: "https://github.com/example/repo/pull/42",
      followUp: "Share the PR with the reviewer."
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(response)
    let decoded = try JSONDecoder().decode(WorkspaceAgentControlResponse.self, from: data)

    #expect(decoded == response)
  }

  @Test("prompt contract includes response path and request id")
  func promptContractIncludesResponsePathAndRequestID() throws {
    let request = WorkspaceAgentControlRequest.reviewSummary(
      repoRoot: "/tmp/repo",
      worktreePath: "/tmp/repo/feature",
      branchName: "feature/window",
      baseRef: "origin/main",
      compareURL: nil
    )

    let prompt = try request.promptWithResponseContract(
      responseFilePath: "/tmp/repo/.tmp/argon-agent-control/response.json"
    )

    #expect(prompt.contains("Structured response contract:"))
    #expect(prompt.contains("/tmp/repo/.tmp/argon-agent-control/response.json"))
    #expect(prompt.contains(request.id.uuidString))
    #expect(prompt.contains("\"kind\" : \"review_summary\""))
  }
}
