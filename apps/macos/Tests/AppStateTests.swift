import Foundation
import Testing

@testable import Argon

@MainActor
@Suite("AppState")
struct AppStateTests {

  @Test("selectFile matches both file id and path")
  func selectFileMatchesIdAndPath() {
    let state = AppState()
    let first = makeFile(path: "Sources/First.swift", lineText: "first")
    let second = makeFile(path: "Sources/Second.swift", lineText: "second")
    state.files = [first, second]

    let byPath = state.selectFile(matching: second.newPath)
    #expect(byPath?.id == second.id)
    #expect(state.selectedFile?.id == second.id)

    let byId = state.selectFile(matching: first.id)
    #expect(byId?.id == first.id)
    #expect(state.selectedFile?.id == first.id)
  }

  @Test("navigating to a search match selects its file")
  func searchNavigationSelectsMatchingFile() {
    let state = AppState()
    let first = makeFile(path: "Sources/First.swift", lineText: "first")
    let second = makeFile(path: "Sources/Second.swift", lineText: "needle")
    state.files = [first, second]
    state.selectedFile = first
    state.searchMatches = [
      SearchMatch(anchor: second.hunks[0].lines[0].anchor, filePath: second.newPath)
    ]

    state.navigateToNextMatch()

    #expect(state.selectedFile?.id == second.id)
    #expect(state.diffNavigationRequest?.anchor == second.hunks[0].lines[0].anchor)
    #expect(state.diffNavigationRequest?.fallbackFileID == second.id)
  }

  @Test("requesting a mode switch confirms before wiping review state")
  func requestModeSwitchPromptsBeforeWipingReviewState() {
    let state = AppState()
    state.activeMode = .uncommitted
    state.session = makeSessionWithThread()

    state.requestModeSwitch(.branch)

    #expect(state.showModeSwitchAlert)
    #expect(state.pendingModeSwitch == .branch)
  }

  @Test("mode switching is disabled while reviewer agents are running")
  func modeSwitchDisabledWhileReviewerAgentsRunning() {
    let state = AppState()
    state.reviewerAgents = [makeReviewerAgent()]

    #expect(!state.canSwitchReviewMode)
    #expect(state.modeSwitchDisabledReason != nil)
  }

  private func makeFile(path: String, lineText: String) -> FileDiff {
    let line = DiffLine(kind: .added, content: lineText, oldLine: nil, newLine: 1)
    let hunk = DiffHunk(header: "@@ -0,0 +1 @@", oldStart: 0, newStart: 1, lines: [line])
    return FileDiff(oldPath: path, newPath: path, hunks: [hunk])
  }

  private func makeSessionWithThread() -> ReviewSession {
    let sessionId = UUID()
    let threadId = UUID()
    let anchor = CommentAnchor(filePath: "Sources/First.swift", lineNew: 1, lineOld: nil)
    let comment = ReviewComment(
      id: UUID(),
      threadId: threadId,
      author: .reviewer,
      authorName: "Frost",
      kind: .line,
      anchor: anchor,
      body: "issue: fix this",
      createdAt: Date()
    )
    let thread = ReviewThread(
      id: threadId,
      state: .open,
      agentAcknowledgedAt: nil,
      comments: [comment]
    )
    return ReviewSession(
      id: sessionId,
      repoRoot: "/tmp/repo",
      mode: .uncommitted,
      baseRef: "HEAD",
      headRef: "WORKTREE",
      mergeBaseSha: "abc123",
      changeSummary: nil,
      status: .awaitingReviewer,
      threads: [thread],
      decision: nil,
      agentLastSeenAt: nil,
      createdAt: Date(),
      updatedAt: Date()
    )
  }

  private func makeReviewerAgent() -> ReviewerAgentInstance {
    ReviewerAgentInstance(
      nickname: "Frost",
      profile: AgentProfile(
        id: "codex",
        name: "Codex",
        command: "codex",
        icon: "terminal",
        isDetected: true
      ),
      sandboxEnabled: false,
      focusPrompt: nil,
      sessionId: UUID().uuidString,
      repoRoot: "/tmp/repo"
    )
  }
}
