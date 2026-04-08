import SwiftUI

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
  var scrollToFile: String?

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
  var scrollToSearchMatch: UUID?
  var scrollToThread: String?

  // Focus triggers
  var focusFileFilter = false

  // Active inline comment editor
  var activeCommentLineId: UUID?
  var activeCommentText: String = ""
  var showDiscardAlert = false
  var pendingCommentLineId: UUID?

  var activeMode: ReviewMode = .uncommitted
  var activeBaseRef: String = "HEAD"
  var activeHeadRef: String = "WORKTREE"
  var activeMergeBaseSha: String = ""

  var detectedBaseRef: String?
  var detectedHeadRef: String?

  var sessionId: String?
  var repoRoot: String?

  private var fileWatcher: FileWatcher?
  private var sessionWatcher: FileWatcher?
  private var diffRefreshTask: Task<Void, Never>?
  private var lastDiffFingerprint: String = ""

  init() {
    applyDefaultDiffMode()
  }

  init(sessionId: String, repoRoot: String) {
    applyDefaultDiffMode()
    self.sessionId = sessionId
    self.repoRoot = repoRoot
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
        applyNewFiles(data.files)
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
    }
  }

  // MARK: - Switch Mode

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
    let detectedBase: String?
    let detectedHead: String?
    let diffFingerprint: String
  }

  private struct SwitchData: Sendable {
    let target: ResolvedTarget
    let files: [FileDiff]
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
      let detectedBase = GitService.inferBaseRef(repoRoot: repoRoot)
      let detectedHead = GitService.currentBranchName(repoRoot: repoRoot)
      let fingerprint = GitService.diffFingerprint(
        repoRoot: repoRoot, mode: session.mode,
        baseRef: session.baseRef, headRef: session.headRef,
        mergeBaseSha: session.mergeBaseSha
      )
      return .success(
        LoadData(
          session: session, files: files, detectedBase: detectedBase, detectedHead: detectedHead,
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

    var updatedSession: ReviewSession?
    if let sessionId {
      try? ArgonCLI.updateSessionTarget(
        sessionId: sessionId, repoRoot: repoRoot,
        mode: target.mode.rawValue, baseRef: target.baseRef,
        headRef: target.headRef, mergeBaseSha: target.mergeBaseSha
      )
      updatedSession = try? SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
    }

    return .success(SwitchData(target: target, files: files, updatedSession: updatedSession))
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

  func requestCommentEditor(for lineId: UUID) {
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

  private func openCommentEditor(for lineId: UUID) {
    activeCommentText = ""
    activeCommentLineId = lineId
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
      applyNewFiles(newFiles)
    }
    lastDiffFingerprint = fingerprint
  }

  func closeSession() {
    guard let sessionId, let repoRoot else { return }
    do {
      try ArgonCLI.closeSession(sessionId: sessionId, repoRoot: repoRoot)
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
    return "\(cli) --repo \(repoRoot) agent prompt --session \(sessionId)"
  }

  // MARK: - File Navigation

  func navigateToNextFile() {
    guard !files.isEmpty else { return }
    if let current = selectedFile,
      let idx = files.firstIndex(where: { $0.id == current.id }),
      idx + 1 < files.count
    {
      selectedFile = files[idx + 1]
      scrollToFile = files[idx + 1].id
    } else {
      selectedFile = files.first
      scrollToFile = files.first?.id
    }
  }

  func navigateToPreviousFile() {
    guard !files.isEmpty else { return }
    if let current = selectedFile,
      let idx = files.firstIndex(where: { $0.id == current.id }),
      idx > 0
    {
      selectedFile = files[idx - 1]
      scrollToFile = files[idx - 1].id
    } else {
      selectedFile = files.last
      scrollToFile = files.last?.id
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
            matches.append(SearchMatch(lineId: line.id, filePath: file.newPath))
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
    scrollToSearchMatch = searchMatches[currentSearchMatchIndex].lineId
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
}

struct SearchMatch: Identifiable {
  let id = UUID()
  let lineId: UUID
  let filePath: String
}
