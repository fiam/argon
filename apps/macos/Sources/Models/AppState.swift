import SwiftUI

enum CoderConnectionState: Equatable {
  case awaitingConnection
  case connected(lastSeenAt: Date)
}

enum DiffViewportRestoreMode: Equatable {
  case gapAnchor
  case nextVisibleRow
  case previousVisibleRow
  case origin
}

struct DiffViewportRestoreRequest: Identifiable, Equatable {
  let id: UUID
  let mode: DiffViewportRestoreMode
  let anchor: DiffAnchor?

  init(id: UUID = UUID(), mode: DiffViewportRestoreMode, anchor: DiffAnchor? = nil) {
    self.id = id
    self.mode = mode
    self.anchor = anchor
  }
}

@MainActor
@Observable
final class AppState {
  var session: ReviewSession?
  var files: [FileDiff] = []
  var selectedFile: FileDiff?
  var errorMessage: String?
  var isLoading = false
  var isPolling = false
  var pendingDrafts: [DraftComment] = []
  var diffNavigationRequest: DiffNavigationRequest?
  var diffContextSources: [String: DiffContextSource] = [:]
  var diffContextExpansion: [String: DiffContextExpansion] = [:]
  var diffViewportRestoreRequest: DiffViewportRestoreRequest?

  // Reviewer agents
  var reviewerAgents: [ReviewerAgentInstance] = []
  var showAgentTerminals = false

  // Diff view mode toggle
  var diffMode: DiffViewMode = .unified

  // Search
  var showSearch = false
  var searchQuery = ""
  var searchMatches: [SearchMatch] = []
  var currentSearchMatchIndex = 0

  // Focus triggers
  var focusFileFilter = false

  // Active inline comment editor
  var activeCommentLineId: String?
  var activeCommentText: String = ""
  var showDiscardAlert = false
  var pendingCommentLineId: String?
  var showModeSwitchAlert = false
  var pendingModeSwitch: ReviewMode?

  var activeMode: ReviewMode = .uncommitted
  var activeBaseRef: String = "HEAD"
  var activeHeadRef: String = "WORKTREE"
  var activeMergeBaseSha: String = ""

  var detectedBaseRef: String?
  var detectedHeadRef: String?

  var sessionId: String?
  var repoRoot: String?
  var reviewLaunchContext: ReviewLaunchContext = .standalone

  private var fileWatcher: FileWatcher?
  private var sessionWatcher: FileWatcher?
  private var diffRefreshTask: Task<Void, Never>?
  private var lastDiffFingerprint: String = ""
  private let uiTestAutomationConfig: UITestAutomationConfig
  private var didRunUITestAutomation = false

  init() {
    uiTestAutomationConfig = .current()
    applyDefaultDiffMode()
  }

  init(sessionId: String, repoRoot: String) {
    uiTestAutomationConfig = .current()
    applyDefaultDiffMode()
    self.sessionId = sessionId
    self.repoRoot = repoRoot
  }

  init(sessionId: String, repoRoot: String, reviewLaunchContext: ReviewLaunchContext) {
    uiTestAutomationConfig = .current()
    applyDefaultDiffMode()
    self.sessionId = sessionId
    self.repoRoot = repoRoot
    self.reviewLaunchContext = reviewLaunchContext
  }

  private func applyDefaultDiffMode() {
    if let saved = UserDefaults.standard.string(forKey: "defaultDiffViewMode"),
      saved == "sideBySide"
    {
      diffMode = .sideBySide
    }
  }

  /// Returns the theme name appropriate for the current system appearance.
  var highlightTheme: String {
    let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark ? "base16-ocean.dark" : "base16-ocean.light"
  }

  // MARK: - Load

  func loadSession() {
    UITestAutomationSignal.write("load-session-started", to: uiTestAutomationConfig.signalFilePath)
    guard let sessionId, let repoRoot else {
      errorMessage = "No session. Run: argon . from a git repo"
      return
    }

    isLoading = true
    let sid = sessionId
    let root = repoRoot
    let theme = highlightTheme

    Task {
      let result = await Task.detached {
        Self.doLoadSession(sessionId: sid, repoRoot: root, theme: theme)
      }.value

      isLoading = false
      switch result {
      case .success(let data):
        session = data.session
        activeMode = data.session.mode
        activeBaseRef = data.session.baseRef
        activeHeadRef = data.session.headRef
        activeMergeBaseSha = data.session.mergeBaseSha
        detectedBaseRef = data.detectedBase
        detectedHeadRef = data.detectedHead
        lastDiffFingerprint = data.diffFingerprint
        diffContextSources = data.contextSources
        applyNewFiles(data.files)
        UITestAutomationSignal.write("session-loaded", to: uiTestAutomationConfig.signalFilePath)
        runUITestAutomationIfNeeded()
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Switch Mode

  var canSwitchReviewMode: Bool {
    reviewerAgents.isEmpty
  }

  var modeSwitchDisabledReason: String? {
    guard !canSwitchReviewMode else { return nil }
    return
      "Review target switching is disabled while reviewer agents are running because it clears review threads, drafts, and the current decision."
  }

  var modeSwitchRequiresConfirmation: Bool {
    let hasSessionThreads = !(session?.threads.isEmpty ?? true)
    let hasDecision = session?.decision != nil
    let hasUnsavedInlineComment =
      !activeCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return hasSessionThreads || hasDecision || !pendingDrafts.isEmpty || hasUnsavedInlineComment
  }

  func requestModeSwitch(_ mode: ReviewMode) {
    guard canSwitchReviewMode else { return }
    guard mode != activeMode else { return }
    if modeSwitchRequiresConfirmation {
      pendingModeSwitch = mode
      showModeSwitchAlert = true
      return
    }
    switchMode(mode)
  }

  func confirmModeSwitch() {
    guard let mode = pendingModeSwitch else { return }
    pendingModeSwitch = nil
    showModeSwitchAlert = false
    activeCommentLineId = nil
    activeCommentText = ""
    switchMode(mode)
  }

  func cancelModeSwitch() {
    pendingModeSwitch = nil
    showModeSwitchAlert = false
  }

  func switchMode(_ mode: ReviewMode) {
    guard let repoRoot else { return }
    isLoading = true

    let sid = sessionId
    let root = repoRoot
    let dBase = detectedBaseRef
    let dHead = detectedHeadRef
    let theme = highlightTheme

    Task {
      let result = await Task.detached {
        Self.doSwitchMode(
          mode: mode, repoRoot: root, sessionId: sid,
          detectedBase: dBase, detectedHead: dHead,
          theme: theme
        )
      }.value

      isLoading = false
      switch result {
      case .success(let data):
        activeMode = data.target.mode
        activeBaseRef = data.target.baseRef
        activeHeadRef = data.target.headRef
        activeMergeBaseSha = data.target.mergeBaseSha
        pendingDrafts = []
        activeCommentLineId = nil
        activeCommentText = ""
        diffContextSources = data.contextSources
        applyNewFiles(data.files)
        if let s = data.updatedSession {
          session = s
        }
      case .failure(let err):
        errorMessage = err.localizedDescription
      }
    }
  }

  // MARK: - Background helpers

  private enum SwitchError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
      switch self {
      case .failed(let msg): msg
      }
    }
  }

  /// Replace the file list while preserving the selected file by path.
  private func applyNewFiles(_ newFiles: [FileDiff]) {
    let previousPath = selectedFile?.displayPath
    files = newFiles
    if let previousPath,
      let match = newFiles.first(where: { $0.displayPath == previousPath })
    {
      selectedFile = match
    } else {
      selectedFile = newFiles.first
    }
  }

  private struct LoadData: Sendable {
    let session: ReviewSession
    let files: [FileDiff]
    let contextSources: [String: DiffContextSource]
    let detectedBase: String?
    let detectedHead: String?
    let diffFingerprint: String
  }

  private struct SwitchData: Sendable {
    let target: ResolvedTarget
    let files: [FileDiff]
    let contextSources: [String: DiffContextSource]
    let updatedSession: ReviewSession?
  }

  /// Try to load highlighted diff from the CLI; fall back to raw git diff if unavailable.
  nonisolated private static func loadFiles(
    sessionId: String?, repoRoot: String, mode: ReviewMode,
    baseRef: String, headRef: String, mergeBaseSha: String,
    theme: String
  ) -> [FileDiff] {
    if let sessionId {
      if let json = try? ArgonCLI.highlightedDiff(
        sessionId: sessionId, repoRoot: repoRoot, theme: theme
      ) {
        let files = DiffParser.parseHighlighted(json)
        if !files.isEmpty {
          return files
        }
      }
    }
    // Fallback to raw git diff
    let rawDiff = GitService.diff(
      repoRoot: repoRoot, mode: mode,
      baseRef: baseRef, headRef: headRef,
      mergeBaseSha: mergeBaseSha
    )
    return DiffParser.parse(rawDiff)
  }

  nonisolated private static func loadContextSources(
    files: [FileDiff],
    repoRoot: String,
    mode: ReviewMode,
    baseRef: String,
    headRef: String,
    mergeBaseSha: String
  ) -> [String: DiffContextSource] {
    GitService.contextSources(
      for: files,
      repoRoot: repoRoot,
      mode: mode,
      baseRef: baseRef,
      headRef: headRef,
      mergeBaseSha: mergeBaseSha
    )
  }

  nonisolated private static func doLoadSession(
    sessionId: String, repoRoot: String, theme: String
  ) -> Result<LoadData, Error> {
    do {
      let session = try SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
      let files = loadFiles(
        sessionId: sessionId, repoRoot: repoRoot,
        mode: session.mode, baseRef: session.baseRef,
        headRef: session.headRef, mergeBaseSha: session.mergeBaseSha,
        theme: theme
      )
      let contextSources = loadContextSources(
        files: files,
        repoRoot: repoRoot,
        mode: session.mode,
        baseRef: session.baseRef,
        headRef: session.headRef,
        mergeBaseSha: session.mergeBaseSha
      )
      let detectedBase = GitService.inferBaseRef(repoRoot: repoRoot)
      let detectedHead = GitService.currentBranchName(repoRoot: repoRoot)
      let fingerprint = GitService.diffFingerprint(
        repoRoot: repoRoot, mode: session.mode,
        baseRef: session.baseRef, headRef: session.headRef,
        mergeBaseSha: session.mergeBaseSha
      )
      return .success(
        LoadData(
          session: session,
          files: files,
          contextSources: contextSources,
          detectedBase: detectedBase,
          detectedHead: detectedHead,
          diffFingerprint: fingerprint))
    } catch {
      return .failure(error)
    }
  }

  nonisolated private static func doSwitchMode(
    mode: ReviewMode, repoRoot: String, sessionId: String?,
    detectedBase: String?, detectedHead: String?,
    theme: String
  ) -> Result<SwitchData, SwitchError> {

    let target: ResolvedTarget?
    switch mode {
    case .branch:
      let base = detectedBase ?? "main"
      let head = detectedHead ?? "HEAD"

      target = GitService.resolveBranchTarget(repoRoot: repoRoot, baseRef: base, headRef: head)
    case .commit:
      target = GitService.resolveCommitTarget(repoRoot: repoRoot)
    case .uncommitted:
      target = GitService.resolveUncommittedTarget(repoRoot: repoRoot)
    }

    guard let target else {
      return .failure(.failed("Could not resolve \(mode.rawValue) target"))
    }

    let files = loadFiles(
      sessionId: sessionId, repoRoot: repoRoot,
      mode: target.mode, baseRef: target.baseRef,
      headRef: target.headRef, mergeBaseSha: target.mergeBaseSha,
      theme: theme
    )
    let contextSources = loadContextSources(
      files: files,
      repoRoot: repoRoot,
      mode: target.mode,
      baseRef: target.baseRef,
      headRef: target.headRef,
      mergeBaseSha: target.mergeBaseSha
    )

    var updatedSession: ReviewSession?
    if let sessionId {
      try? ArgonCLI.updateSessionTarget(
        sessionId: sessionId, repoRoot: repoRoot,
        mode: target.mode.rawValue, baseRef: target.baseRef,
        headRef: target.headRef, mergeBaseSha: target.mergeBaseSha
      )
      updatedSession = try? SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
    }

    return .success(
      SwitchData(
        target: target,
        files: files,
        contextSources: contextSources,
        updatedSession: updatedSession
      )
    )
  }

  // MARK: - Polling

  func refreshSession() {
    guard let sessionId, let repoRoot else { return }
    do {
      let s = try SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
      session = s
      updateAgentStates(from: s)
    } catch {}
  }

  private func updateAgentStates(from session: ReviewSession) {
    for agent in reviewerAgents {
      let agentComments = session.threads.flatMap(\.comments).filter {
        $0.authorName == agent.nickname
      }
      agent.hasComments = !agentComments.isEmpty

      // Check if the session decision was likely from this agent
      // (last comment before decision was from this agent)
      if let decision = session.decision {
        let allComments = session.threads.flatMap(\.comments).sorted { $0.createdAt < $1.createdAt }
        if let lastBeforeDecision = allComments.last(where: {
          $0.createdAt <= decision.createdAt && $0.authorName == agent.nickname
        }) {
          // If this agent's last comment was close to the decision time, attribute it
          let gap = decision.createdAt.timeIntervalSince(lastBeforeDecision.createdAt)
          if gap < 30 {  // within 30 seconds
            agent.lastDecision = decision.outcome.rawValue
          }
        }
      }
    }
  }

  func reload() {
    errorMessage = nil
    loadSession()
  }

  func startPolling() {
    guard !isPolling else { return }
    isPolling = true

    // Watch session store for comment/decision changes
    if let repoRoot, sessionWatcher == nil {
      let sessionsDir = SessionLoader.sessionsDirectory(repoRoot: repoRoot)
      sessionWatcher = FileWatcher(path: sessionsDir) { [weak self] in
        Task { @MainActor [weak self] in
          self?.refreshSession()
          self?.reloadDrafts()
        }
      }
      sessionWatcher?.start()
    }

    // Watch working tree for diff changes
    if let repoRoot, fileWatcher == nil {
      fileWatcher = FileWatcher(path: repoRoot) { [weak self] in
        Task { @MainActor [weak self] in
          await self?.onFileSystemChange()
        }
      }
      fileWatcher?.start()
    }
  }

  private func onFileSystemChange() async {
    diffRefreshTask?.cancel()
    diffRefreshTask = Task {
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      await checkDiffChanged()
    }
  }

  // MARK: - Inline Comment Editor

  func requestCommentEditor(for lineId: String) {
    // Same line -- toggle off
    if activeCommentLineId == lineId {
      return
    }
    // Another line with unsaved text -- confirm discard
    if activeCommentLineId != nil
      && !activeCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      pendingCommentLineId = lineId
      showDiscardAlert = true
      return
    }
    // Open on new line
    openCommentEditor(for: lineId)
  }

  func confirmDiscard() {
    if let pending = pendingCommentLineId {
      openCommentEditor(for: pending)
    }
    pendingCommentLineId = nil
  }

  func cancelDiscard() {
    pendingCommentLineId = nil
  }

  func closeCommentEditor() {
    activeCommentLineId = nil
    activeCommentText = ""
  }

  private func openCommentEditor(for lineId: String) {
    activeCommentText = ""
    activeCommentLineId = lineId
  }

  func expandOmittedContext(
    _ block: DiffOmittedContextBlock,
    direction: DiffContextExpandDirection,
    chunkSize: Int = 20
  ) {
    let key = block.id
    var expansion = diffContextExpansion[key] ?? DiffContextExpansion()
    let remaining = max(
      0,
      block.totalLineCount - expansion.revealFromTop - expansion.revealFromBottom
    )
    guard remaining > 0 else { return }

    switch direction {
    case .up:
      expansion.revealFromTop += min(chunkSize, remaining)
    case .down:
      expansion.revealFromBottom += min(chunkSize, remaining)
    case .all:
      expansion.revealFromTop = block.totalLineCount
      expansion.revealFromBottom = 0
    }

    let gapRemainsVisible =
      expansion.revealFromTop + expansion.revealFromBottom < block.totalLineCount
    let restoreMode: DiffViewportRestoreMode =
      switch direction {
      case .up where gapRemainsVisible:
        .gapAnchor
      case .up:
        .nextVisibleRow
      case .down where gapRemainsVisible:
        .gapAnchor
      case .down:
        .previousVisibleRow
      case .all:
        .nextVisibleRow
      }

    diffViewportRestoreRequest = DiffViewportRestoreRequest(
      mode: restoreMode,
      anchor: block.anchor
    )
    diffContextExpansion[key] = expansion
  }

  func stopPolling() {
    sessionWatcher?.stop()
    sessionWatcher = nil
    diffRefreshTask?.cancel()
    diffRefreshTask = nil
    fileWatcher?.stop()
    fileWatcher = nil
    isPolling = false
  }

  private func checkDiffChanged() async {
    guard let repoRoot else { return }
    let mode = activeMode
    let base = activeBaseRef
    let head = activeHeadRef
    let mergeBase = activeMergeBaseSha
    let sid = sessionId
    let theme = highlightTheme

    let fingerprint = await Task.detached {
      GitService.diffFingerprint(
        repoRoot: repoRoot, mode: mode,
        baseRef: base, headRef: head, mergeBaseSha: mergeBase
      )
    }.value

    if fingerprint != lastDiffFingerprint && !lastDiffFingerprint.isEmpty {
      // Diff changed -- refresh in background
      let newFiles = await Task.detached {
        Self.loadFiles(
          sessionId: sid, repoRoot: repoRoot,
          mode: mode, baseRef: base,
          headRef: head, mergeBaseSha: mergeBase,
          theme: theme
        )
      }.value
      let newContextSources = await Task.detached {
        Self.loadContextSources(
          files: newFiles,
          repoRoot: repoRoot,
          mode: mode,
          baseRef: base,
          headRef: head,
          mergeBaseSha: mergeBase
        )
      }.value
      diffContextSources = newContextSources
      applyNewFiles(newFiles)
    }
    lastDiffFingerprint = fingerprint
  }

  func closeSession() {
    guard let sessionId, let repoRoot else { return }
    do {
      try ArgonCLI.closeSession(sessionId: sessionId, repoRoot: repoRoot)
      ReviewSessionLifecycle.postSessionClosed(repoRoot: repoRoot)
      refreshSession()
    } catch {}
    stopPolling()
  }

  // MARK: - Draft Review

  func addDraft(
    message: String, filePath: String? = nil, lineNew: UInt32? = nil, lineOld: UInt32? = nil,
    threadId: String? = nil
  ) {
    guard let sessionId, let repoRoot else { return }
    do {
      try ArgonCLI.addDraftComment(
        sessionId: sessionId, repoRoot: repoRoot,
        message: message, filePath: filePath,
        lineNew: lineNew, lineOld: lineOld, threadId: threadId
      )
      reloadDrafts()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func resolveThread(_ threadId: String) {
    guard let sessionId, let repoRoot else { return }
    do {
      try ArgonCLI.resolveThread(sessionId: sessionId, repoRoot: repoRoot, threadId: threadId)
      refreshSession()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func replyToThread(_ threadId: String, message: String) {
    guard let sessionId, let repoRoot else { return }
    do {
      try ArgonCLI.addComment(
        sessionId: sessionId, repoRoot: repoRoot,
        message: message, threadId: threadId
      )
      refreshSession()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func deleteDraft(_ draftId: String) {
    guard let sessionId, let repoRoot else { return }
    do {
      try ArgonCLI.deleteDraftComment(sessionId: sessionId, repoRoot: repoRoot, draftId: draftId)
      reloadDrafts()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func submitReview(outcome: String?, summary: String? = nil) {
    guard let sessionId, let repoRoot else { return }
    do {
      try ArgonCLI.submitReview(
        sessionId: sessionId, repoRoot: repoRoot,
        outcome: outcome, summary: summary
      )
      pendingDrafts = []
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reloadDrafts() {
    guard let sessionId, let repoRoot else { return }
    do {
      pendingDrafts = try SessionLoader.loadDraftReview(sessionId: sessionId, repoRoot: repoRoot)
    } catch {
      pendingDrafts = []
    }
  }

  var handoffCommand: String {
    guard let sessionId, let repoRoot else { return "" }
    let cli = ProcessInfo.processInfo.environment["ARGON_CLI_CMD"] ?? "argon"
    return "\(cli) --repo \(shellQuote(repoRoot)) agent prompt --session \(sessionId)"
  }

  var coderHasConnected: Bool {
    session?.agentLastSeenAt != nil
  }

  var coderConnectionState: CoderConnectionState {
    if let lastSeenAt = session?.agentLastSeenAt {
      return .connected(lastSeenAt: lastSeenAt)
    }
    return .awaitingConnection
  }

  var coderNeedsPromptHandoff: Bool {
    guard let session else { return false }
    return session.status != .approved && session.status != .closed
      && coderConnectionState == .awaitingConnection
      && reviewLaunchContext == .standalone
  }

  var coderHandoffPendingFromWorkspace: Bool {
    reviewLaunchContext == .coderHandoff && coderConnectionState == .awaitingConnection
  }

  var showsCoderSetupActions: Bool {
    reviewLaunchContext == .standalone
  }

  var coderConnectionLabel: String {
    switch coderConnectionState {
    case .awaitingConnection:
      reviewLaunchContext == .coderHandoff ? "Connecting coder" : "No coder yet"
    case .connected:
      "Coder connected"
    }
  }

  var coderConnectionHelpText: String {
    switch coderConnectionState {
    case .awaitingConnection:
      if reviewLaunchContext == .coderHandoff {
        return
          "Argon handed this session to the selected coder tab and is waiting for the first heartbeat."
      }
      return "No coder agent heartbeat yet. Copy Agent Prompt to hand off this session."
    case .connected(let lastSeenAt):
      return
        "A coder agent has connected to this session. Last heartbeat \(relativeTimeDescription(since: lastSeenAt))."
    }
  }

  var handoffPrompt: String {
    guard let session, let repoRoot else { return "" }

    let cli = ProcessInfo.processInfo.environment["ARGON_CLI_CMD"] ?? "argon"
    let continueCommand =
      "\(cli) --repo \(shellQuote(repoRoot)) agent wait --session \(session.id.uuidString) --json"
    var lines: [String] = []
    lines.append("You are reviewing feedback for Argon session \(session.id) in \(repoRoot).")
    lines.append(
      "Review target: mode=\(session.mode.rawValue) base=\(session.baseRef) head=\(session.headRef)"
    )
    if let changeSummary = session.changeSummary, !changeSummary.isEmpty {
      lines.append("Planned changes for this review: \(changeSummary)")
    }
    lines.append("Execution contract:")
    lines.append(
      "1) Use this blocking wait command to pause until reviewer activity or a final state: \(continueCommand)"
    )
    lines.append(
      "2) If the current snapshot already has open reviewer threads, address them now. Otherwise run the wait command and react as soon as it returns reviewer feedback."
    )
    lines.append(
      "   acknowledge command template: \(cli) --repo \(shellQuote(repoRoot)) agent ack --session \(session.id.uuidString) --thread <thread-id>"
    )
    lines.append(
      "3) After acknowledging, implement the changes and reply on every acknowledged thread."
    )
    lines.append(
      "   reply command template: \(cli) --repo \(shellQuote(repoRoot)) agent reply --session \(session.id.uuidString) --thread <thread-id> --message \"<what changed>\" --addressed"
    )
    lines.append(
      "4) After replying, run the same wait command again and continue this loop without disconnecting."
    )
    lines.append(
      "5) If the wait command returns `approved`, commit your changes (unless the reviewer explicitly asked for a different finalization step) and then stop. If it returns `closed`, the human ended the Argon session. Those are the only terminal states."
    )
    lines.append(
      "6) Do not keep a background `agent follow --jsonl` process as the primary loop in Codex; its output does not drive the agent's control flow."
    )
    lines.append(
      "7) Do not stop just because another reviewer agent says the work looks good; keep going until the human approves or closes the session."
    )

    if let decision = session.decision {
      let summary = decision.summary?.isEmpty == false ? decision.summary! : "no summary"
      lines.append(
        "Current reviewer decision snapshot: \(decision.outcome.rawValue) — \(summary)."
      )
      lines.append(
        "Treat non-terminal reviewer decisions as part of the active review. Address them if needed, then stay in the wait loop until the session is approved or closed."
      )
    }

    let pending = currentPendingFeedback(for: session)
    if pending.isEmpty {
      lines.append("Current snapshot: no open reviewer threads right now.")
    } else {
      lines.append("Current snapshot: pending reviewer feedback (address immediately):")
      for (index, item) in pending.enumerated() {
        let anchor: String = {
          if let path = item.anchor.filePath {
            return
              "\(path) (old:\(String(describing: item.anchor.lineOld)) new:\(String(describing: item.anchor.lineNew)))"
          }
          return "global"
        }()
        lines.append(
          "\(index + 1). thread \(item.threadID.uuidString) at \(anchor) -> \(item.comment)"
        )
        lines.append(
          "   acknowledge with: \(cli) --repo \(shellQuote(repoRoot)) agent ack --session \(session.id.uuidString) --thread \(item.threadID.uuidString)"
        )
        lines.append(
          "   reply with: \(cli) --repo \(shellQuote(repoRoot)) agent reply --session \(session.id.uuidString) --thread \(item.threadID.uuidString) --message \"<what changed>\" --addressed"
        )
      }
      lines.append("Address these now while keeping the stream open.")
    }

    return lines.joined(separator: "\n")
  }

  // MARK: - File Navigation

  func navigateToNextFile() {
    guard !files.isEmpty else { return }
    if let current = selectedFile,
      let idx = files.firstIndex(where: { $0.id == current.id }),
      idx + 1 < files.count
    {
      navigateToFile(files[idx + 1])
    } else {
      if let first = files.first {
        navigateToFile(first)
      }
    }
  }

  func navigateToPreviousFile() {
    guard !files.isEmpty else { return }
    if let current = selectedFile,
      let idx = files.firstIndex(where: { $0.id == current.id }),
      idx > 0
    {
      navigateToFile(files[idx - 1])
    } else {
      if let last = files.last {
        navigateToFile(last)
      }
    }
  }

  func toggleSearch() {
    showSearch.toggle()
    if !showSearch {
      searchQuery = ""
      searchMatches = []
      currentSearchMatchIndex = 0
    }
  }

  private struct PendingHandoffFeedback {
    let threadID: UUID
    let anchor: CommentAnchor
    let comment: String
  }

  private func relativeTimeDescription(since date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  private func currentPendingFeedback(for session: ReviewSession) -> [PendingHandoffFeedback] {
    session.threads.compactMap { thread in
      guard thread.state == .open, let latest = thread.comments.last, latest.author == .reviewer
      else { return nil }
      return PendingHandoffFeedback(
        threadID: thread.id, anchor: latest.anchor, comment: latest.body)
    }
  }

  private func shellQuote(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: "/._-:+")
    )
    if !raw.isEmpty, raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
      return raw
    }
    return "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  func updateSearchMatches() {
    let query = searchQuery.lowercased()
    guard !query.isEmpty else {
      searchMatches = []
      currentSearchMatchIndex = 0
      return
    }

    var matches: [SearchMatch] = []
    for file in files {
      for hunk in file.hunks {
        for line in hunk.lines {
          if line.content.lowercased().contains(query) {
            matches.append(SearchMatch(anchor: line.anchor, filePath: file.newPath))
          }
        }
      }
    }
    searchMatches = matches
    if currentSearchMatchIndex >= matches.count {
      currentSearchMatchIndex = 0
    }
  }

  func navigateToNextMatch() {
    guard !searchMatches.isEmpty else { return }
    currentSearchMatchIndex = (currentSearchMatchIndex + 1) % searchMatches.count
    scrollToCurrentMatch()
  }

  func navigateToPreviousMatch() {
    guard !searchMatches.isEmpty else { return }
    currentSearchMatchIndex =
      (currentSearchMatchIndex - 1 + searchMatches.count) % searchMatches.count
    scrollToCurrentMatch()
  }

  private func scrollToCurrentMatch() {
    guard currentSearchMatchIndex < searchMatches.count else { return }
    let match = searchMatches[currentSearchMatchIndex]
    if let file = selectFile(matching: match.filePath) {
      requestDiffNavigation(
        to: match.anchor,
        fallbackFileID: file.id,
        alignment: .center,
        animated: true
      )
    }
  }

  @discardableResult
  func selectFile(matching identifier: String) -> FileDiff? {
    guard let file = file(matching: identifier) else { return nil }
    selectedFile = file
    return file
  }

  func file(matching identifier: String) -> FileDiff? {
    files.first { file in
      file.id == identifier
        || file.anchor.id == identifier
        || file.newPath == identifier
        || file.displayPath == identifier
    }
  }

  func navigateToFile(_ file: FileDiff) {
    selectedFile = file
    requestDiffNavigation(to: file.anchor)
  }

  func requestDiffNavigation(
    to anchor: DiffAnchor,
    fallbackFileID: String? = nil,
    alignment: DiffNavigationAlignment = .top,
    animated: Bool = false
  ) {
    diffNavigationRequest = DiffNavigationRequest(
      anchor: anchor,
      fallbackFileID: fallbackFileID,
      alignment: alignment,
      animated: animated
    )
  }

  func clearDiffNavigationRequest(_ requestID: UUID) {
    guard diffNavigationRequest?.id == requestID else { return }
    diffNavigationRequest = nil
  }

  func clearDiffViewportRestoreRequest(_ requestID: UUID) {
    guard diffViewportRestoreRequest?.id == requestID else { return }
    diffViewportRestoreRequest = nil
  }

  func dismissAll() {
    if showSearch {
      toggleSearch()
    } else if activeCommentLineId != nil {
      closeCommentEditor()
    }
  }

  // MARK: - Reviewer Agents

  func launchReviewerAgent(profile: AgentProfile, focusPrompt: String?, sandboxEnabled: Bool) {
    guard let sessionId, let repoRoot else { return }
    let nickname = DetectiveNames.next()
    let agent = ReviewerAgentInstance(
      nickname: nickname,
      profile: profile,
      sandboxEnabled: sandboxEnabled,
      focusPrompt: focusPrompt,
      sessionId: sessionId,
      repoRoot: repoRoot
    )
    reviewerAgents.append(agent)
    showAgentTerminals = true
  }

  func stopReviewerAgent(_ id: UUID) {
    if let idx = reviewerAgents.firstIndex(where: { $0.id == id }) {
      reviewerAgents[idx].stop()
      reviewerAgents.remove(at: idx)
    }
    if reviewerAgents.isEmpty {
      showAgentTerminals = false
    }
  }

  func stopAllReviewerAgents() {
    for agent in reviewerAgents {
      agent.stop()
    }
    reviewerAgents.removeAll()
    showAgentTerminals = false
  }

  private func runUITestAutomationIfNeeded() {
    guard !didRunUITestAutomation, let reviewerLaunch = uiTestAutomationConfig.reviewerLaunch else {
      return
    }
    didRunUITestAutomation = true

    let profile = AgentProfile(
      id: "ui-test-reviewer",
      name: "UI Test Reviewer",
      command: reviewerLaunch.command,
      icon: "terminal",
      isDetected: false
    )

    Task { @MainActor in
      await Task.yield()
      launchReviewerAgent(
        profile: profile,
        focusPrompt: reviewerLaunch.focusPrompt,
        sandboxEnabled: reviewerLaunch.sandboxEnabled
      )
      UITestAutomationSignal.write("reviewer-launched", to: uiTestAutomationConfig.signalFilePath)
    }
  }
}

struct SearchMatch: Identifiable {
  let anchor: DiffAnchor
  let filePath: String

  var id: String {
    anchor.id
  }
}
