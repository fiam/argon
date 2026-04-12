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

  @Test("coder prompt handoff is highlighted before first agent heartbeat")
  func coderPromptHandoffNeedsAttentionBeforeFirstHeartbeat() {
    let state = AppState()
    state.sessionId = UUID().uuidString.lowercased()
    state.repoRoot = "/tmp/repo path"
    state.session = makeSessionWithThread()

    #expect(!state.coderHasConnected)
    #expect(state.coderNeedsPromptHandoff)
    #expect(state.coderConnectionState == .awaitingConnection)
    #expect(state.coderConnectionLabel == "No coder yet")
    #expect(state.coderConnectionHelpText.contains("No coder agent heartbeat yet"))
    #expect(state.handoffPrompt.contains("commit your changes"))
    #expect(state.handoffPrompt.contains("continue this loop without disconnecting"))
    #expect(state.handoffPrompt.contains("issue: fix this"))
  }

  @Test("coder prompt handoff quiets down after first heartbeat")
  func coderPromptHandoffStopsNeedingAttentionAfterHeartbeat() {
    let state = AppState()
    state.sessionId = UUID().uuidString.lowercased()
    state.repoRoot = "/tmp/repo"
    var session = makeSessionWithThread()
    session = ReviewSession(
      id: session.id,
      repoRoot: session.repoRoot,
      mode: session.mode,
      baseRef: session.baseRef,
      headRef: session.headRef,
      mergeBaseSha: session.mergeBaseSha,
      changeSummary: session.changeSummary,
      status: session.status,
      threads: session.threads,
      decision: session.decision,
      agentLastSeenAt: Date(),
      createdAt: session.createdAt,
      updatedAt: session.updatedAt
    )
    state.session = session

    #expect(state.coderHasConnected)
    #expect(!state.coderNeedsPromptHandoff)
    #expect(state.coderConnectionLabel == "Coder connected")
    #expect(state.coderConnectionHelpText.contains("Last heartbeat"))
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
