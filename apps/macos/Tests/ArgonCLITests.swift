import XCTest

@testable import Argon

final class ArgonCLITests: XCTestCase {
  func testExtractAgentPromptTextStripsCliEnvelope() {
    let output = """
      session: c5b43e0f-9853-4c03-b1da-dd4ec7b4f49a
      status: AwaitingReviewer
      pending-feedback: 0
      agent-prompt-command: /tmp/argon --repo /tmp/repo agent prompt --session c5b43e0f-9853-4c03-b1da-dd4ec7b4f49a
      continue-command: /tmp/argon --repo /tmp/repo agent wait --session c5b43e0f-9853-4c03-b1da-dd4ec7b4f49a --json

      You are reviewing feedback for Argon session c5b43e0f-9853-4c03-b1da-dd4ec7b4f49a in /tmp/repo.
      Review target: mode=uncommitted base=HEAD head=WORKTREE
      Execution contract:
      1) Use this blocking wait command to pause until reviewer activity or a final state: /tmp/argon --repo /tmp/repo agent wait --session c5b43e0f-9853-4c03-b1da-dd4ec7b4f49a --json
      """

    let prompt = ArgonCLI.extractAgentPromptText(from: output)

    XCTAssertTrue(
      prompt.hasPrefix(
        "You are reviewing feedback for Argon session c5b43e0f-9853-4c03-b1da-dd4ec7b4f49a"))
    XCTAssertTrue(prompt.contains("Execution contract:"))
    XCTAssertFalse(prompt.contains("agent-prompt-command:"))
    XCTAssertFalse(prompt.contains("continue-command: /tmp/argon"))
  }

  func testExtractAgentPromptTextPreservesPlainPromptOutput() {
    let output = """
      You are reviewing feedback for Argon session.
      Execution contract:
      1) Wait.
      """

    XCTAssertEqual(ArgonCLI.extractAgentPromptText(from: output), output)
  }
}
