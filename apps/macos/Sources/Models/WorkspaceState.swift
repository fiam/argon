import Foundation

@MainActor
@Observable
final class WorkspaceState {
  var worktrees: [DiscoveredWorktree] = []
  var worktreeSummaries: [String: WorktreeDiffSummary] = [:]
  var reviewSnapshotsByWorktreePath: [String: WorkspaceReviewSnapshot] = [:]
  var conflictStatesByWorktreePath: [String: Bool] = [:]
  var selectedWorktreePath: String?
  var selectedSummary: WorktreeDiffSummary = .empty
  var selectedFiles: [FileDiff] = []
  var selectedDiffStat = ""
  var selectedPullRequestURL: String?
  var selectedReviewTarget: ResolvedTarget?
  var selectedUpdatedAt: Date?
  var errorMessage: String?
  var launchWarningMessage: String?
  var isLoading = false
  var isLaunchingReview = false
  var isCreatingWorktree = false
  var isPresentingTabCreationSheet = false
  var isPresentingAgentLaunchSheet = false
  var terminalTabsByWorktreePath: [String: [WorkspaceTerminalTab]] = [:]
  var selectedTerminalTabIDsByWorktreePath: [String: UUID] = [:]
  var terminalFocusRequestIDsByWorktreePath: [String: UUID] = [:]

  let target: WorkspaceTarget

  private var commonDirWatcher: FileWatcher?
  private var worktreeWatchersByPath: [String: FileWatcher] = [:]
  private var workspaceReloadTask: Task<Void, Never>?
  private var worktreeRefreshTasksByPath: [String: Task<Void, Never>] = [:]

  init(target: WorkspaceTarget) {
    self.target = target
    self.selectedWorktreePath = target.selectedWorktreePath ?? target.repoRoot
    self.launchWarningMessage = Self.launchWarningMessage(for: target)
  }

  var repoName: String {
    URL(fileURLWithPath: target.repoRoot).lastPathComponent
  }

  var selectedWorktree: DiscoveredWorktree? {
    guard let selectedPath = normalizedSelectedWorktreePath else {
      return worktrees.first
    }
    return
      worktrees.first { normalizedPath($0.path) == selectedPath }
      ?? worktrees.first
  }

  var normalizedSelectedWorktreePath: String? {
    guard let selectedWorktreePath else { return nil }
    return normalizedPath(selectedWorktreePath)
  }

  var selectedTerminalTabs: [WorkspaceTerminalTab] {
    guard let path = normalizedSelectedWorktreePath else { return [] }
    return terminalTabsByWorktreePath[path] ?? []
  }

  var allTerminalTabs: [WorkspaceTerminalTab] {
    terminalTabsByWorktreePath.values
      .flatMap { $0 }
      .sorted { $0.createdAt < $1.createdAt }
  }

  var selectedTerminalTab: WorkspaceTerminalTab? {
    guard let worktreePath = normalizedSelectedWorktreePath else { return nil }
    let tabs = terminalTabsByWorktreePath[worktreePath] ?? []
    guard !tabs.isEmpty else { return nil }

    if let selectedID = selectedTerminalTabIDsByWorktreePath[worktreePath],
      let selectedTab = tabs.first(where: { $0.id == selectedID })
    {
      return selectedTab
    }

    return tabs.first
  }

  var selectedReviewSnapshot: WorkspaceReviewSnapshot? {
    guard let path = normalizedSelectedWorktreePath else { return nil }
    return reviewSnapshotsByWorktreePath[path]
  }

  var selectedTerminalFocusRequestID: UUID? {
    guard let path = normalizedSelectedWorktreePath else { return nil }
    return terminalFocusRequestIDsByWorktreePath[path]
  }

  func load() {
    let requestedSelection = normalizedSelectedWorktreePath ?? normalizedPath(target.repoRoot)
    isLoading = true

    let target = self.target
    Task {
      let result = await Task.detached {
        try Self.loadWorkspace(target: target, requestedSelection: requestedSelection)
      }.result

      switch result {
      case .success(let data):
        applyLoadedWorkspace(data)
        errorMessage = nil
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
      isLoading = false
    }
  }

  func refresh() {
    load()
  }

  func applyLaunchTarget(_ target: WorkspaceTarget) {
    launchWarningMessage = Self.launchWarningMessage(for: target)

    let requestedSelection = normalizedPath(target.selectedWorktreePath ?? target.repoRoot)
    guard normalizedSelectedWorktreePath != requestedSelection else {
      if worktrees.isEmpty && !isLoading {
        selectedWorktreePath = requestedSelection
        load()
      }
      return
    }

    if worktrees.isEmpty {
      selectedWorktreePath = requestedSelection
      if !isLoading {
        load()
      }
      return
    }

    selectWorktree(path: requestedSelection)
  }

  func selectWorktree(path: String) {
    let normalizedPath = normalizedPath(path)
    selectedWorktreePath = normalizedPath
    loadSelectedWorktreeDetails(for: normalizedPath)
  }

  func createReviewTarget() async throws -> ReviewTarget {
    guard let selectedWorktree else {
      throw GitService.GitError.commandFailed("Select a worktree before starting review.")
    }

    isLaunchingReview = true
    defer { isLaunchingReview = false }
    let worktreePath = normalizedPath(selectedWorktree.path)
    let reviewTarget = try await Task.detached {
      try ArgonCLI.createSession(repoRoot: selectedWorktree.path)
    }.value

    if let session = try? SessionLoader.loadSession(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot
    ) {
      reviewSnapshotsByWorktreePath[worktreePath] = WorkspaceReviewSnapshot(session: session)
    }
    selectedUpdatedAt = Date()
    return reviewTarget
  }

  func createWorktree(branchName: String, path: String, startPoint: String) async throws {
    let trimmedBranchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedStartPoint = startPoint.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedBranchName.isEmpty else {
      throw GitService.GitError.commandFailed("Enter a branch name for the new worktree.")
    }

    guard !trimmedPath.isEmpty else {
      throw GitService.GitError.commandFailed("Enter a destination path for the new worktree.")
    }

    isCreatingWorktree = true
    defer { isCreatingWorktree = false }

    let target = self.target
    let normalizedPath = normalizedPath(trimmedPath)

    try await Task.detached {
      try GitService.createWorktree(
        repoRoot: target.repoRoot,
        branchName: trimmedBranchName,
        path: normalizedPath,
        startPoint: trimmedStartPoint
      )
    }.value

    let loadedWorkspace = try await Task.detached {
      try Self.loadWorkspace(target: target, requestedSelection: normalizedPath)
    }.value

    applyLoadedWorkspace(loadedWorkspace)
    errorMessage = nil
  }

  func summary(for worktreePath: String) -> WorktreeDiffSummary {
    worktreeSummaries[normalizedPath(worktreePath)] ?? .empty
  }

  func reviewSnapshot(for worktreePath: String) -> WorkspaceReviewSnapshot? {
    reviewSnapshotsByWorktreePath[normalizedPath(worktreePath)]
  }

  func hasConflicts(for worktreePath: String) -> Bool {
    conflictStatesByWorktreePath[normalizedPath(worktreePath)] ?? false
  }

  func activeAgentCount(for worktreePath: String) -> Int {
    let tabs = terminalTabsByWorktreePath[normalizedPath(worktreePath)] ?? []
    return tabs.reduce(into: 0) { count, tab in
      if case .agent = tab.kind, tab.isRunning {
        count += 1
      }
    }
  }

  func defaultNewWorktreeStartPoint() -> String {
    selectedReviewTarget?.baseRef
      ?? GitService.inferBaseRef(repoRoot: target.repoRoot)
      ?? "HEAD"
  }

  func suggestedWorktreePath(branchName: String) -> String {
    let repoRootURL = URL(fileURLWithPath: target.repoRoot).standardizedFileURL
    let parentURL = repoRootURL.deletingLastPathComponent()
    let suffix =
      slugifiedBranchName(branchName).isEmpty ? "worktree" : slugifiedBranchName(branchName)
    return parentURL.appendingPathComponent("\(repoName)-\(suffix)").path
  }

  func presentAgentLaunchSheet() {
    guard selectedWorktree != nil else { return }
    isPresentingAgentLaunchSheet = true
  }

  func presentTabCreationSheet() {
    guard selectedWorktree != nil else { return }
    isPresentingTabCreationSheet = true
  }

  func dismissTabCreationSheet() {
    isPresentingTabCreationSheet = false
  }

  func dismissAgentLaunchSheet() {
    isPresentingAgentLaunchSheet = false
  }

  func openShellTab(sandboxed: Bool = false) {
    guard let worktree = selectedWorktree else { return }

    let worktreePath = normalizedPath(worktree.path)
    let ordinal = nextOrdinal(in: worktreePath) { tab in
      if case .shell = tab.kind {
        return true
      }
      return false
    }

    let tab = WorkspaceTerminalTab(
      worktreePath: worktreePath,
      worktreeLabel: worktree.branchName ?? repoName,
      title: sandboxed ? "Sandboxed Shell \(ordinal)" : "Shell \(ordinal)",
      commandDescription: sandboxed
        ? "Sandboxed \(UserShell.resolvedPath())"
        : UserShell
          .resolvedPath(),
      kind: .shell,
      launch: sandboxed
        ? TerminalLaunchConfiguration.sandboxedShell(
          currentDirectory: worktree.path,
          writableRoots: [worktree.path]
        )
        : TerminalLaunchConfiguration.shell(currentDirectory: worktree.path),
      isSandboxed: sandboxed
    )

    insertTerminalTab(tab, for: worktreePath)
  }

  func openAgentTab(_ request: WorkspaceAgentLaunchRequest) {
    guard let worktree = selectedWorktree else { return }

    let worktreePath = normalizedPath(worktree.path)
    let ordinal = nextOrdinal(in: worktreePath) { tab in
      if case .agent(let profileName, _) = tab.kind {
        return profileName == request.displayName
      }
      return false
    }

    let launch =
      if request.sandboxEnabled {
        TerminalLaunchConfiguration.sandboxedCommand(
          request.command,
          currentDirectory: worktree.path,
          writableRoots: [worktree.path]
        )
      } else {
        TerminalLaunchConfiguration.command(request.command, currentDirectory: worktree.path)
      }

    let tab = WorkspaceTerminalTab(
      worktreePath: worktreePath,
      worktreeLabel: worktree.branchName ?? repoName,
      title: ordinal == 1 ? request.displayName : "\(request.displayName) \(ordinal)",
      commandDescription: request.command,
      kind: .agent(profileName: request.displayName, icon: request.icon),
      launch: launch,
      isSandboxed: request.sandboxEnabled
    )

    insertTerminalTab(tab, for: worktreePath)
  }

  func selectTerminalTab(_ tabID: UUID) {
    guard let worktreePath = normalizedSelectedWorktreePath else { return }
    selectedTerminalTabIDsByWorktreePath[worktreePath] = tabID
    requestTerminalFocus(in: worktreePath)
  }

  func closeTerminalTab(_ tabID: UUID) {
    for (worktreePath, tabs) in terminalTabsByWorktreePath {
      guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { continue }

      var updatedTabs = tabs
      updatedTabs.remove(at: index)
      terminalTabsByWorktreePath[worktreePath] = updatedTabs

      if selectedTerminalTabIDsByWorktreePath[worktreePath] == tabID {
        selectedTerminalTabIDsByWorktreePath[worktreePath] =
          updatedTabs.indices.contains(index) ? updatedTabs[index].id : updatedTabs.last?.id
        if selectedTerminalTabIDsByWorktreePath[worktreePath] != nil {
          requestTerminalFocus(in: worktreePath)
        } else {
          terminalFocusRequestIDsByWorktreePath.removeValue(forKey: worktreePath)
        }
      }
      return
    }
  }

  func handleTerminalExit(_ tabID: UUID, shellExitBehavior: WorkspaceShellExitBehavior) {
    guard let tab = terminalTab(for: tabID) else { return }
    tab.isRunning = false

    guard case .shell = tab.kind, shellExitBehavior == .closeTab else { return }

    Task { @MainActor [weak self] in
      self?.closeTerminalTab(tabID)
    }
  }

  private func loadSelectedWorktreeDetails(for path: String) {
    isLoading = true

    Task {
      let result = await Task.detached {
        Self.loadSelectionDetails(for: path)
      }.result

      switch result {
      case .success(let details):
        if normalizedSelectedWorktreePath == path {
          worktreeSummaries[path] = details.summary
          selectedSummary = details.summary
          selectedFiles = details.files
          selectedDiffStat = details.diffStat
          selectedPullRequestURL = details.pullRequestURL
          selectedReviewTarget = details.reviewTarget
          selectedUpdatedAt = Date()
        }
        errorMessage = nil
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
      isLoading = false
    }
  }

  nonisolated private static func loadWorkspace(
    target: WorkspaceTarget,
    requestedSelection: String
  ) throws -> LoadedWorkspace {
    let worktrees = try GitService.discoverWorktrees(
      repoRoot: target.repoRoot,
      repoCommonDir: target.repoCommonDir
    )
    let normalizedPaths = Set(worktrees.map { normalizedPath($0.path) })
    let worktreeSummaries = Dictionary(
      uniqueKeysWithValues: worktrees.map { worktree in
        let normalized = normalizedPath(worktree.path)
        return (normalized, GitService.diffSummary(repoRoot: worktree.path))
      }
    )
    let reviewSnapshotsByWorktreePath = SessionLoader.latestReviewSnapshots(
      forRepoRoots: normalizedPaths)
    let conflictStatesByWorktreePath = Dictionary(
      uniqueKeysWithValues: worktrees.map { worktree in
        let normalized = normalizedPath(worktree.path)
        return (normalized, GitService.hasConflicts(repoRoot: worktree.path))
      }
    )
    let selectedWorktreePath =
      worktrees.first(where: { normalizedPath($0.path) == requestedSelection })?.path
      ?? worktrees.first?.path
      ?? target.repoRoot
    let details = loadSelectionDetails(
      for: selectedWorktreePath,
      summary: worktreeSummaries[normalizedPath(selectedWorktreePath)]
    )

    return LoadedWorkspace(
      worktrees: worktrees,
      worktreeSummaries: worktreeSummaries,
      reviewSnapshotsByWorktreePath: reviewSnapshotsByWorktreePath,
      conflictStatesByWorktreePath: conflictStatesByWorktreePath,
      selectedWorktreePath: selectedWorktreePath,
      selectedSummary: details.summary,
      selectedFiles: details.files,
      selectedDiffStat: details.diffStat,
      selectedPullRequestURL: details.pullRequestURL,
      selectedReviewTarget: details.reviewTarget
    )
  }

  nonisolated private static func loadSelectionDetails(
    for path: String,
    summary: WorktreeDiffSummary? = nil
  ) -> SelectionDetails {
    let files = GitService.diffFiles(repoRoot: path)
    let resolvedSummary =
      summary
      ?? (files.isEmpty
        ? .empty
        : WorktreeDiffSummary(
          fileCount: files.count,
          addedLineCount: files.reduce(0) { $0 + $1.addedCount },
          removedLineCount: files.reduce(0) { $0 + $1.removedCount }
        ))

    return SelectionDetails(
      summary: resolvedSummary,
      files: files,
      diffStat: GitService.formatDiffStat(files: files),
      pullRequestURL: GitService.autoDetectTarget(repoRoot: path).flatMap { target in
        GitService.pullRequestCompareURL(
          repoRoot: path,
          mode: target.mode,
          baseRef: target.baseRef,
          headRef: target.headRef
        )
      },
      reviewTarget: GitService.autoDetectTarget(repoRoot: path)
    )
  }

  nonisolated private static func loadRefreshedWorktree(for path: String) -> RefreshedWorktree {
    let details = loadSelectionDetails(for: path)
    return RefreshedWorktree(
      summary: details.summary,
      files: details.files,
      diffStat: details.diffStat,
      pullRequestURL: details.pullRequestURL,
      reviewTarget: details.reviewTarget,
      hasConflicts: GitService.hasConflicts(repoRoot: path)
    )
  }

  nonisolated private static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  nonisolated private static func launchWarningMessage(for target: WorkspaceTarget) -> String? {
    guard let selectedWorktreePath = target.selectedWorktreePath else { return nil }

    let normalizedRepoRoot = normalizedPath(target.repoRoot)
    let normalizedWorktreePath = normalizedPath(selectedWorktreePath)
    guard normalizedRepoRoot != normalizedWorktreePath else { return nil }

    return
      "Opened the original repository at \(normalizedRepoRoot) because \(normalizedWorktreePath) is a linked worktree."
  }

  private func normalizedPath(_ path: String) -> String {
    Self.normalizedPath(path)
  }

  private func applyLoadedWorkspace(_ data: LoadedWorkspace) {
    worktrees = data.worktrees
    worktreeSummaries = data.worktreeSummaries
    reviewSnapshotsByWorktreePath = data.reviewSnapshotsByWorktreePath
    conflictStatesByWorktreePath = data.conflictStatesByWorktreePath
    selectedWorktreePath = data.selectedWorktreePath
    selectedSummary = data.selectedSummary
    selectedFiles = data.selectedFiles
    selectedDiffStat = data.selectedDiffStat
    selectedPullRequestURL = data.selectedPullRequestURL
    selectedReviewTarget = data.selectedReviewTarget
    selectedUpdatedAt = Date()
    let validPaths = Set(data.worktrees.map { normalizedPath($0.path) })
    pruneTerminalState(validPaths: validPaths)
    configureWatchers(validPaths: validPaths)
  }

  func applyRefreshedWorktree(_ refreshedWorktree: RefreshedWorktree, for path: String) {
    worktreeSummaries[path] = refreshedWorktree.summary
    conflictStatesByWorktreePath[path] = refreshedWorktree.hasConflicts

    guard normalizedSelectedWorktreePath == path else { return }

    selectedSummary = refreshedWorktree.summary
    selectedFiles = refreshedWorktree.files
    selectedDiffStat = refreshedWorktree.diffStat
    selectedPullRequestURL = refreshedWorktree.pullRequestURL
    selectedReviewTarget = refreshedWorktree.reviewTarget
    selectedUpdatedAt = Date()
  }

  private func insertTerminalTab(_ tab: WorkspaceTerminalTab, for worktreePath: String) {
    terminalTabsByWorktreePath[worktreePath, default: []].append(tab)
    selectedTerminalTabIDsByWorktreePath[worktreePath] = tab.id
    requestTerminalFocus(in: worktreePath)
  }

  private func nextOrdinal(
    in worktreePath: String,
    where predicate: (WorkspaceTerminalTab) -> Bool
  ) -> Int {
    (terminalTabsByWorktreePath[worktreePath] ?? []).filter(predicate).count + 1
  }

  private func pruneTerminalState(validPaths: Set<String>) {
    terminalTabsByWorktreePath =
      terminalTabsByWorktreePath
      .filter { validPaths.contains($0.key) }
    selectedTerminalTabIDsByWorktreePath =
      selectedTerminalTabIDsByWorktreePath
      .filter { validPaths.contains($0.key) }
    terminalFocusRequestIDsByWorktreePath =
      terminalFocusRequestIDsByWorktreePath
      .filter { validPaths.contains($0.key) }
  }

  private func configureWatchers(validPaths: Set<String>) {
    if commonDirWatcher == nil {
      commonDirWatcher = FileWatcher(path: target.repoCommonDir) { [weak self] in
        Task { @MainActor [weak self] in
          self?.scheduleWorkspaceReload()
        }
      }
      commonDirWatcher?.start()
    }

    let stalePaths = Set(worktreeWatchersByPath.keys).subtracting(validPaths)
    for stalePath in stalePaths {
      worktreeWatchersByPath[stalePath]?.stop()
      worktreeWatchersByPath.removeValue(forKey: stalePath)
      worktreeRefreshTasksByPath[stalePath]?.cancel()
      worktreeRefreshTasksByPath.removeValue(forKey: stalePath)
    }

    for path in validPaths where worktreeWatchersByPath[path] == nil {
      let watcher = FileWatcher(path: path) { [weak self] in
        Task { @MainActor [weak self] in
          self?.scheduleWorktreeRefresh(for: path)
        }
      }
      worktreeWatchersByPath[path] = watcher
      watcher.start()
    }
  }

  private func scheduleWorkspaceReload() {
    workspaceReloadTask?.cancel()
    workspaceReloadTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard let self, !Task.isCancelled else { return }
      self.load()
    }
  }

  private func scheduleWorktreeRefresh(for path: String) {
    let normalizedPath = normalizedPath(path)
    worktreeRefreshTasksByPath[normalizedPath]?.cancel()
    worktreeRefreshTasksByPath[normalizedPath] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard let self, !Task.isCancelled else { return }
      await self.refreshWorktree(path: normalizedPath)
    }
  }

  private func refreshWorktree(path: String) async {
    let result = await Task.detached {
      Self.loadRefreshedWorktree(for: path)
    }.result

    switch result {
    case .success(let refreshedWorktree):
      applyRefreshedWorktree(refreshedWorktree, for: path)
      errorMessage = nil
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }

  private func terminalTab(for tabID: UUID) -> WorkspaceTerminalTab? {
    terminalTabsByWorktreePath.values
      .joined()
      .first { $0.id == tabID }
  }

  private func slugifiedBranchName(_ branchName: String) -> String {
    branchName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(
        of: "[^a-z0-9]+",
        with: "-",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private func requestTerminalFocus(in worktreePath: String) {
    terminalFocusRequestIDsByWorktreePath[worktreePath] = UUID()
  }
}

struct RefreshedWorktree: Sendable {
  let summary: WorktreeDiffSummary
  let files: [FileDiff]
  let diffStat: String
  let pullRequestURL: String?
  let reviewTarget: ResolvedTarget?
  let hasConflicts: Bool
}

private struct LoadedWorkspace: Sendable {
  let worktrees: [DiscoveredWorktree]
  let worktreeSummaries: [String: WorktreeDiffSummary]
  let reviewSnapshotsByWorktreePath: [String: WorkspaceReviewSnapshot]
  let conflictStatesByWorktreePath: [String: Bool]
  let selectedWorktreePath: String
  let selectedSummary: WorktreeDiffSummary
  let selectedFiles: [FileDiff]
  let selectedDiffStat: String
  let selectedPullRequestURL: String?
  let selectedReviewTarget: ResolvedTarget?
}

private struct SelectionDetails: Sendable {
  let summary: WorktreeDiffSummary
  let files: [FileDiff]
  let diffStat: String
  let pullRequestURL: String?
  let reviewTarget: ResolvedTarget?
}
