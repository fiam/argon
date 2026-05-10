import Foundation

extension WorkspaceState {
  func presentNewWorktreeSheet() {
    isPresentingNewWorktreeSheet = true
  }

  func dismissNewWorktreeSheet() {
    isPresentingNewWorktreeSheet = false
  }

  func selectDiffMode(_ mode: WorkspaceDiffMode) {
    guard let selectedWorktree else { return }
    let path = normalizedPath(selectedWorktree.path)
    let effectiveMode = Self.effectiveDiffMode(for: selectedWorktree, requested: mode)
    guard selectedDiffMode != effectiveMode else { return }

    diffModesByWorktreePath[path] = effectiveMode
    prepareSelectionLoading(for: path)
    loadSelectedWorktreeDetails(for: path)
  }

  func requestedDiffMode(for path: String) -> WorkspaceDiffMode {
    diffModesByWorktreePath[normalizedPath(path)] ?? .allChanges
  }

  func effectiveDiffMode(for worktree: DiscoveredWorktree) -> WorkspaceDiffMode {
    Self.effectiveDiffMode(for: worktree, requested: requestedDiffMode(for: worktree.path))
  }

  func effectiveDiffMode(for path: String) -> WorkspaceDiffMode {
    guard let worktree = worktrees.first(where: { normalizedPath($0.path) == normalizedPath(path) })
    else {
      return requestedDiffMode(for: path)
    }
    return effectiveDiffMode(for: worktree)
  }

  nonisolated static func supportsAllChangesDiff(for worktree: DiscoveredWorktree) -> Bool {
    guard !worktree.isBaseWorktree, !worktree.isDetached else { return false }
    return !(worktree.branchName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  nonisolated static func effectiveDiffMode(
    for worktree: DiscoveredWorktree,
    requested: WorkspaceDiffMode
  ) -> WorkspaceDiffMode {
    supportsAllChangesDiff(for: worktree) ? requested : .uncommitted
  }

  func load() {
    let requestedSelection = normalizedSelectedWorktreePath ?? normalizedPath(target.repoRoot)
    isLoading = true

    let target = self.target
    let diffModesByWorktreePath = self.diffModesByWorktreePath
    Task {
      let result = await Task.detached {
        try Self.loadWorkspace(
          target: target,
          requestedSelection: requestedSelection,
          diffModesByWorktreePath: diffModesByWorktreePath
        )
      }.result

      switch result {
      case .success(let data):
        applyLoadedWorkspace(data)
        errorMessage = nil
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
      selectionLoadRequestID = nil
      isLoadingSelectionDetails = false
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
        notifyRestorableStateChanged()
        load()
      }
      return
    }

    if worktrees.isEmpty {
      selectedWorktreePath = requestedSelection
      notifyRestorableStateChanged()
      if !isLoading {
        load()
      }
      return
    }

    selectWorktree(path: requestedSelection)
  }

  func selectWorktree(path: String) {
    let normalizedPath = normalizedPath(path)
    prepareSelectionLoading(for: normalizedPath)
    loadSelectedWorktreeDetails(for: normalizedPath)
  }

  var canSelectNextWorktree: Bool {
    worktrees.count > 1
  }

  var canSelectPreviousWorktree: Bool {
    worktrees.count > 1
  }

  @discardableResult
  func selectNextWorktree() -> Bool {
    selectWorktree(offset: 1)
  }

  @discardableResult
  func selectPreviousWorktree() -> Bool {
    selectWorktree(offset: -1)
  }

  func createReviewTarget(
    launchContext: ReviewLaunchContext = .standalone,
    changeSummary: String? = nil
  ) async throws
    -> ReviewTarget
  {
    guard let selectedWorktree else {
      throw GitService.GitError.commandFailed("Select a worktree before starting review.")
    }

    isLaunchingReview = true
    defer { isLaunchingReview = false }
    let worktreePath = normalizedPath(selectedWorktree.path)
    let diffMode = selectedDiffMode
    let sessionTarget: ResolvedTarget?
    if let selectedReviewTarget {
      sessionTarget = selectedReviewTarget
    } else {
      sessionTarget = await Task.detached {
        GitService.resolveWorkspaceTarget(repoRoot: selectedWorktree.path, diffMode: diffMode)
      }.value
    }
    var reviewTarget = try await Task.detached {
      try ArgonCLI.createSession(
        repoRoot: selectedWorktree.path,
        target: sessionTarget,
        changeSummary: changeSummary
      )
    }.value
    reviewTarget = ReviewTarget(
      sessionId: reviewTarget.sessionId,
      repoRoot: reviewTarget.repoRoot,
      launchContext: launchContext
    )

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
      try Self.loadWorkspace(
        target: target,
        requestedSelection: normalizedPath,
        diffModesByWorktreePath: [:]
      )
    }.value

    applyLoadedWorkspace(loadedWorkspace)
    errorMessage = nil
  }

  func prepareWorktreeRemoval(for worktree: DiscoveredWorktree) async throws
    -> WorktreeRemovalRequest
  {
    guard !worktree.isBaseWorktree else {
      throw GitService.GitError.commandFailed("The base worktree cannot be removed.")
    }

    let normalizedWorktreePath = normalizedPath(worktree.path)
    let target = self.target
    let branchDetails = await Task.detached {
      let normalizedBranchName = worktree.branchName?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let currentBranch = GitService.currentBranchName(repoRoot: target.repoRoot)
      let canDeleteBranch =
        if let normalizedBranchName, !normalizedBranchName.isEmpty {
          normalizedBranchName != currentBranch
        } else {
          false
        }
      let baseRef =
        canDeleteBranch
        ? GitService.preferredBranchDeletionBaseRef(
          repoRoot: target.repoRoot,
          branchName: normalizedBranchName
        )
        : nil

      return WorktreeRemovalBranchDetails(
        hasUncommittedChanges: GitService.hasUncommittedChanges(repoRoot: normalizedWorktreePath),
        hasInitializedSubmodules: GitService.hasInitializedSubmodules(
          repoRoot: normalizedWorktreePath
        ),
        submodulesWithUnpushedCommits: GitService.submodulesWithUnpushedCommits(
          repoRoot: normalizedWorktreePath
        ),
        branchName: normalizedBranchName,
        canDeleteBranch: canDeleteBranch,
        branchComparisonBaseRef: baseRef,
        branchHasUniqueCommits:
          canDeleteBranch
          && GitService.branchHasUniqueCommits(
            repoRoot: target.repoRoot,
            branchName: normalizedBranchName ?? "",
            baseRef: baseRef
          ),
        branchHasUnpushedCommits:
          canDeleteBranch
          && GitService.branchHasUnpushedCommits(
            repoRoot: target.repoRoot,
            branchName: normalizedBranchName ?? "",
            baseRef: baseRef
          )
      )
    }.value

    return WorktreeRemovalRequest(
      worktreePath: normalizedWorktreePath,
      displayName: worktree.branchName
        ?? URL(fileURLWithPath: normalizedWorktreePath).lastPathComponent,
      branchName: branchDetails.branchName,
      hasUncommittedChanges: branchDetails.hasUncommittedChanges,
      hasInitializedSubmodules: branchDetails.hasInitializedSubmodules,
      submodulesWithUnpushedCommits: branchDetails.submodulesWithUnpushedCommits,
      canDeleteBranch: branchDetails.canDeleteBranch,
      branchComparisonBaseRef: branchDetails.branchComparisonBaseRef,
      branchHasUniqueCommits: branchDetails.branchHasUniqueCommits,
      branchHasUnpushedCommits: branchDetails.branchHasUnpushedCommits
    )
  }

  func removeWorktree(_ request: WorktreeRemovalRequest, deleteBranch: Bool) async throws {
    guard request.worktreePath != normalizedPath(target.repoRoot) else {
      throw GitService.GitError.commandFailed("The base worktree cannot be removed.")
    }

    isRemovingWorktree = true
    defer { isRemovingWorktree = false }

    let target = self.target
    try await Task.detached {
      try GitService.removeWorktree(
        repoRoot: target.repoRoot,
        path: request.worktreePath,
        force: request.hasUncommittedChanges
      )
    }.value

    var branchRemovalError: String?
    if deleteBranch, request.canDeleteBranch, let branchName = request.branchName {
      do {
        try await Task.detached {
          try GitService.deleteBranch(
            repoRoot: target.repoRoot,
            branchName: branchName,
            force: request.branchHasUniqueCommits
              || GitService.branchRequiresForceDelete(
                repoRoot: target.repoRoot,
                branchName: branchName,
                baseRef: request.branchComparisonBaseRef
              )
          )
        }.value
      } catch {
        branchRemovalError =
          "Removed the worktree, but could not delete branch \(branchName): \(error.localizedDescription)"
      }
    }

    let discoveredWorktrees = try await Task.detached {
      try Self.loadDiscoveredWorktrees(target: target)
    }.value

    applyDiscoveredWorktreeInventory(discoveredWorktrees)
    if let branchRemovalError {
      throw GitService.GitError.commandFailed(branchRemovalError)
    }
    errorMessage = nil
  }

  func presentWorktreeRemovalError(_ error: any Error, worktreeName: String?) {
    worktreeRemovalErrorDialog = WorkspaceErrorDialog(
      title: "Couldn't Remove Worktree",
      message: Self.worktreeRemovalErrorMessage(
        for: error,
        worktreeName: worktreeName
      )
    )
  }

  func dismissWorktreeRemovalError() {
    worktreeRemovalErrorDialog = nil
  }

  func summary(for worktreePath: String) -> WorktreeDiffSummary {
    worktreeSummaries[normalizedPath(worktreePath)] ?? .empty
  }

  func reviewSnapshot(for worktreePath: String) -> WorkspaceReviewSnapshot? {
    let normalizedPath = normalizedPath(worktreePath)
    guard let snapshot = reviewSnapshotsByWorktreePath[normalizedPath] else { return nil }
    return snapshot.matches(target: reviewTargetsByWorktreePath[normalizedPath] ?? nil)
      ? snapshot : nil
  }

  func reviewSummaryDraft(for worktreePath: String) -> WorkspaceReviewSummaryDraft? {
    reviewSummaryDraftsByWorktreePath[normalizedPath(worktreePath)]
  }

  func hasConflicts(for worktreePath: String) -> Bool {
    conflictStatesByWorktreePath[normalizedPath(worktreePath)] ?? false
  }

  var isMergeBackInProgressForSelectedWorktree: Bool {
    guard let selectedWorktree else { return false }
    return isMergeBackInProgress(for: selectedWorktree.path)
  }

  var isRebaseInProgressForSelectedWorktree: Bool {
    guard let selectedWorktree else { return false }
    return isRebaseInProgress(for: selectedWorktree.path)
  }

  func isRebaseInProgress(for worktreePath: String) -> Bool {
    isFinalizeInProgress(.rebaseOntoBase, for: worktreePath)
  }

  func isMergeBackInProgress(for worktreePath: String) -> Bool {
    let normalizedWorktreePath = normalizedPath(worktreePath)
    if activeLocalMergeBackWorktreePaths.contains(normalizedWorktreePath) {
      return true
    }
    return activeAgentControlRequestsByID.values.contains { pending in
      guard pending.worktreePath == normalizedWorktreePath,
        case .finalize(let action) = pending.request.action
      else {
        return false
      }
      return action.isMergeBackAction
    }
  }

  func isFinalizeInProgress(
    _ action: WorktreeFinalizeAction,
    for worktreePath: String
  ) -> Bool {
    let normalizedWorktreePath = normalizedPath(worktreePath)
    return activeAgentControlRequestsByID.values.contains { pending in
      pending.worktreePath == normalizedWorktreePath
        && pending.request.action == .finalize(action)
    }
  }

  func isMergeBackCompleted(for worktreePath: String) -> Bool {
    completedMergeBackWorktreePaths.contains(normalizedPath(worktreePath))
  }

  var runningAgentCount: Int {
    let materializedCount = allTerminalTabs.reduce(into: 0) { count, tab in
      if case .agent = tab.kind, tab.isRunning {
        count += 1
      }
    }
    return materializedCount
      + pendingRunningBackgroundAgentCount()
  }

  func activeAgentCount(for worktreePath: String) -> Int {
    let normalizedPath = normalizedPath(worktreePath)
    let tabs = terminalTabsByWorktreePath[normalizedPath] ?? []
    let materializedCount = tabs.reduce(into: 0) { count, tab in
      if case .agent = tab.kind, tab.isRunning {
        count += 1
      }
    }
    return materializedCount
      + (pendingAgentActivitySummariesByWorktreePath[normalizedPath]?.runningAgentCount ?? 0)
  }

  func agentActivitySummary(for worktreePath: String) -> WorktreeAgentActivitySummary {
    let normalizedPath = normalizedPath(worktreePath)
    let tabs = terminalTabsByWorktreePath[normalizedPath] ?? []
    let materializedSummary = tabs.reduce(into: .empty) { summary, tab in
      guard case .agent = tab.kind, tab.isRunning else { return }

      summary = WorktreeAgentActivitySummary(
        waitingForHumanCount: summary.waitingForHumanCount
          + (tab.agentActivityState == .waitingForHuman ? 1 : 0),
        thinkingCount: summary.thinkingCount
          + (tab.agentActivityState == .thinking ? 1 : 0),
        runningAgentCount: summary.runningAgentCount + 1
      )
    }
    guard
      let pendingSummary = pendingAgentActivitySummariesByWorktreePath[normalizedPath]
    else {
      return materializedSummary
    }
    return WorktreeAgentActivitySummary(
      waitingForHumanCount: materializedSummary.waitingForHumanCount
        + pendingSummary.waitingForHumanCount,
      thinkingCount: materializedSummary.thinkingCount + pendingSummary.thinkingCount,
      runningAgentCount: materializedSummary.runningAgentCount + pendingSummary.runningAgentCount
    )
  }

  func worktreeNeedsAttention(for worktreePath: String) -> Bool {
    let normalizedPath = normalizedPath(worktreePath)
    let tabs = terminalTabsByWorktreePath[normalizedPath] ?? []
    return tabs.contains { $0.hasAttention }
      || (pendingAgentActivitySummariesByWorktreePath[normalizedPath]?.waitingForHumanCount ?? 0)
        > 0
  }

  func defaultNewWorktreeStartPoint() -> String {
    GitService.defaultWorktreeStartPoint(
      repoRoot: target.repoRoot,
      baseRef: selectedReviewTarget?.baseRef
    )
  }

  func suggestedWorktreePath(branchName: String) -> String {
    let worktreeName =
      slugifiedBranchName(branchName).isEmpty ? "worktree" : slugifiedBranchName(branchName)
    return WorktreeRootSettings.suggestedPath(
      rootPath: worktreeRootPathProvider(),
      repoRoot: target.repoRoot,
      worktreeName: worktreeName
    )
  }

  func loadSelectedWorktreeDetails(for path: String) {
    let requestID = UUID()
    selectionLoadRequestID = requestID
    let diffMode = effectiveDiffMode(for: path)

    Task {
      let result = await Task.detached {
        Self.loadSelectionDetails(for: path, diffMode: diffMode)
      }.result

      switch result {
      case .success(let details):
        if selectionLoadRequestID == requestID, normalizedSelectedWorktreePath == path {
          worktreeSummaries[path] = details.summary
          reviewTargetsByWorktreePath[path] = details.reviewTarget
          selectedSummary = details.summary
          selectedFiles = details.files
          selectedDiffStat = details.diffStat
          selectedPullRequestURL = details.pullRequestURL
          selectedReviewTarget = details.reviewTarget
          selectedBranchTopology = details.branchTopology
          selectedUpdatedAt = Date()
          isLoadingSelectionDetails = false
        }
        errorMessage = nil
      case .failure(let error):
        if selectionLoadRequestID == requestID {
          errorMessage = error.localizedDescription
          isLoadingSelectionDetails = false
        }
      }
    }
  }

  nonisolated static func loadWorkspace(
    target: WorkspaceTarget,
    requestedSelection: String,
    diffModesByWorktreePath: [String: WorkspaceDiffMode]
  ) throws -> LoadedWorkspace {
    let worktrees = try loadDiscoveredWorktrees(target: target)
    let normalizedPaths = Set(worktrees.map { normalizedPath($0.path) })
    let worktreeSummaries = Dictionary(
      uniqueKeysWithValues: worktrees.map { worktree in
        let normalized = normalizedPath(worktree.path)
        let diffMode = effectiveDiffMode(
          for: worktree,
          requested: diffModesByWorktreePath[normalized] ?? .allChanges
        )
        return (normalized, GitService.diffSummary(repoRoot: worktree.path, diffMode: diffMode))
      }
    )
    let reviewTargetsByWorktreePath = Dictionary(
      uniqueKeysWithValues: worktrees.map { worktree in
        let normalized = normalizedPath(worktree.path)
        let diffMode = effectiveDiffMode(
          for: worktree,
          requested: diffModesByWorktreePath[normalized] ?? .allChanges
        )
        return (
          normalized,
          GitService.resolveWorkspaceTarget(repoRoot: worktree.path, diffMode: diffMode)
        )
      }
    )
    let reviewSnapshotsByWorktreePath = SessionLoader.latestReviewSnapshots(
      forRepoRoots: normalizedPaths)
    let conflictStatesByWorktreePath = Dictionary(
      uniqueKeysWithValues: worktrees.map { worktree in
        let normalized = normalizedPath(worktree.path)
        return (
          normalized,
          GitService.hasConflicts(
            repoRoot: worktree.path,
            predictsMergeConflicts: supportsAllChangesDiff(for: worktree)
          )
        )
      }
    )
    let selectedWorktreePath =
      worktrees.first(where: { normalizedPath($0.path) == requestedSelection })?.path
      ?? worktrees.first?.path
      ?? target.repoRoot
    let selectedWorktree = worktrees.first {
      normalizedPath($0.path) == normalizedPath(selectedWorktreePath)
    }
    let selectedDiffMode =
      selectedWorktree.map {
        effectiveDiffMode(
          for: $0,
          requested: diffModesByWorktreePath[normalizedPath($0.path)] ?? .allChanges
        )
      } ?? .uncommitted
    let details = loadSelectionDetails(
      for: selectedWorktreePath,
      diffMode: selectedDiffMode,
      summary: worktreeSummaries[normalizedPath(selectedWorktreePath)]
    )

    return LoadedWorkspace(
      worktrees: worktrees,
      worktreeSummaries: worktreeSummaries,
      reviewTargetsByWorktreePath: reviewTargetsByWorktreePath,
      reviewSnapshotsByWorktreePath: reviewSnapshotsByWorktreePath,
      conflictStatesByWorktreePath: conflictStatesByWorktreePath,
      selectedWorktreePath: selectedWorktreePath,
      selectedSummary: details.summary,
      selectedFiles: details.files,
      selectedDiffStat: details.diffStat,
      selectedPullRequestURL: details.pullRequestURL,
      selectedReviewTarget: details.reviewTarget,
      selectedBranchTopology: details.branchTopology
    )
  }

  nonisolated static func loadDiscoveredWorktrees(target: WorkspaceTarget) throws
    -> [DiscoveredWorktree]
  {
    try GitService.discoverWorktrees(
      repoRoot: target.repoRoot,
      repoCommonDir: target.repoCommonDir
    )
  }

  nonisolated static func shouldReloadWorktreeInventory(
    currentWorktrees: [DiscoveredWorktree],
    discoveredWorktrees: [DiscoveredWorktree]
  ) -> Bool {
    currentWorktrees.map { normalizedPath($0.path) }
      != discoveredWorktrees.map { normalizedPath($0.path) }
  }

  nonisolated static func shouldRefreshWorktreeDetails(
    currentWorktrees: [DiscoveredWorktree],
    discoveredWorktrees: [DiscoveredWorktree]
  ) -> Bool {
    let currentByPath = Dictionary(
      uniqueKeysWithValues: currentWorktrees.map { (normalizedPath($0.path), $0) })

    for discoveredWorktree in discoveredWorktrees {
      let normalized = normalizedPath(discoveredWorktree.path)
      guard let currentWorktree = currentByPath[normalized] else {
        return true
      }
      if currentWorktree.branchName != discoveredWorktree.branchName
        || currentWorktree.headSHA != discoveredWorktree.headSHA
        || currentWorktree.isBaseWorktree != discoveredWorktree.isBaseWorktree
        || currentWorktree.isDetached != discoveredWorktree.isDetached
        || currentWorktree.isRebasing != discoveredWorktree.isRebasing
        || currentWorktree.createdAt != discoveredWorktree.createdAt
      {
        return true
      }
    }

    return false
  }

  nonisolated static func loadSelectionDetails(
    for path: String,
    diffMode: WorkspaceDiffMode,
    summary: WorktreeDiffSummary? = nil
  ) -> SelectionDetails {
    let files = GitService.diffFiles(repoRoot: path, diffMode: diffMode)
    let reviewTarget = GitService.resolveWorkspaceTarget(repoRoot: path, diffMode: diffMode)
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
      pullRequestURL: reviewTarget.flatMap { target in
        GitService.pullRequestURL(
          repoRoot: path,
          mode: target.mode,
          baseRef: target.baseRef,
          headRef: target.headRef
        )
      },
      reviewTarget: reviewTarget,
      branchTopology: reviewTarget.flatMap { target in
        guard target.mode == .branch else { return nil }
        return GitService.branchTopology(
          repoRoot: path,
          baseRef: target.baseRef,
          headRef: target.headRef
        )
      }
    )
  }

  nonisolated static func loadRefreshedWorktree(
    for path: String,
    diffMode: WorkspaceDiffMode,
    predictsMergeConflicts: Bool
  ) -> RefreshedWorktree {
    let details = loadSelectionDetails(for: path, diffMode: diffMode)
    return RefreshedWorktree(
      summary: details.summary,
      files: details.files,
      diffStat: details.diffStat,
      pullRequestURL: details.pullRequestURL,
      reviewTarget: details.reviewTarget,
      branchTopology: details.branchTopology,
      hasConflicts: GitService.hasConflicts(
        repoRoot: path,
        predictsMergeConflicts: predictsMergeConflicts
      )
    )
  }

  nonisolated static func normalizedPath(_ path: String) -> String {
    let normalized = URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    return normalizedDarwinPrivatePath(normalized)
  }

  nonisolated static func normalizedDarwinPrivatePath(_ path: String) -> String {
    for (privatePrefix, publicPrefix) in [
      ("/private/tmp", "/tmp"),
      ("/private/var", "/var"),
      ("/private/etc", "/etc"),
    ] {
      if path == privatePrefix {
        return publicPrefix
      }
      if path.hasPrefix("\(privatePrefix)/") {
        return publicPrefix + path.dropFirst(privatePrefix.count)
      }
    }

    return path
  }

  nonisolated static func launchWarningMessage(for target: WorkspaceTarget) -> String? {
    guard target.showsLinkedWorktreeWarning else { return nil }
    guard let selectedWorktreePath = target.selectedWorktreePath else { return nil }

    let normalizedRepoRoot = normalizedPath(target.repoRoot)
    let normalizedWorktreePath = normalizedPath(selectedWorktreePath)
    guard normalizedRepoRoot != normalizedWorktreePath else { return nil }

    return
      "Opened the original repository at \(normalizedRepoRoot) because \(normalizedWorktreePath) is a linked worktree."
  }

  func normalizedPath(_ path: String) -> String {
    Self.normalizedPath(path)
  }

  func applyLoadedWorkspace(_ data: LoadedWorkspace) {
    worktrees = data.worktrees
    worktreeSummaries = data.worktreeSummaries
    reviewTargetsByWorktreePath = data.reviewTargetsByWorktreePath
    reviewSnapshotsByWorktreePath = data.reviewSnapshotsByWorktreePath
    conflictStatesByWorktreePath = data.conflictStatesByWorktreePath
    selectedWorktreePath = data.selectedWorktreePath
    selectedSummary = data.selectedSummary
    selectedFiles = data.selectedFiles
    selectedDiffStat = data.selectedDiffStat
    selectedPullRequestURL = data.selectedPullRequestURL
    selectedReviewTarget = data.selectedReviewTarget
    selectedBranchTopology = data.selectedBranchTopology
    selectedUpdatedAt = Date()
    selectionLoadRequestID = nil
    isLoadingSelectionDetails = false
    let validPaths = Set(data.worktrees.map { normalizedPath($0.path) })
    pruneWorktreeState(validPaths: validPaths)
    configureWatchers(validPaths: validPaths)
    let selectedWorktreePath = normalizedPath(data.selectedWorktreePath)
    materializePendingRunningAgentTabs(for: selectedWorktreePath)
    startRunningBackgroundAgentRestores(
      validPaths: validPaths,
      excluding: selectedWorktreePath
    )
    startPendingTabRestoreIfNeeded(for: selectedWorktreePath)
    notifyRestorableStateChanged()
  }

  func applyDiscoveredWorktreeInventory(_ discoveredWorktrees: [DiscoveredWorktree]) {
    guard
      Self.shouldReloadWorktreeInventory(
        currentWorktrees: worktrees,
        discoveredWorktrees: discoveredWorktrees
      )
    else {
      guard
        Self.shouldRefreshWorktreeDetails(
          currentWorktrees: worktrees,
          discoveredWorktrees: discoveredWorktrees
        )
      else { return }

      worktrees = discoveredWorktrees
      scheduleAllWorktreeRefreshes()
      startRunningBackgroundAgentRestores(
        validPaths: Set(discoveredWorktrees.map { normalizedPath($0.path) }),
        excluding: normalizedSelectedWorktreePath
      )
      return
    }

    let currentWorktrees = worktrees
    let currentPaths = Set(currentWorktrees.map { normalizedPath($0.path) })
    let validPaths = Set(discoveredWorktrees.map { normalizedPath($0.path) })
    let addedPaths = validPaths.subtracting(currentPaths)
    let preservedSelection = normalizedSelectedWorktreePath
    let preferredSelection =
      preservedSelection ?? normalizedPath(target.selectedWorktreePath ?? target.repoRoot)

    worktrees = discoveredWorktrees
    pruneWorktreeState(validPaths: validPaths)
    configureWatchers(validPaths: validPaths)
    startRunningBackgroundAgentRestores(
      validPaths: validPaths,
      excluding: preservedSelection
    )

    if let nextSelection = resolvedInventorySelectionPath(
      preferredSelection: preferredSelection,
      validPaths: validPaths,
      previousWorktrees: currentWorktrees,
      discoveredWorktrees: discoveredWorktrees
    ) {
      if nextSelection == preservedSelection {
        selectedWorktreePath = nextSelection
        startPendingTabRestoreIfNeeded(for: nextSelection)
        notifyRestorableStateChanged()
      } else {
        prepareSelectionLoading(for: nextSelection)
        loadSelectedWorktreeDetails(for: nextSelection)
      }
    } else {
      clearSelectedWorktreeDetails()
    }

    for addedPath in addedPaths {
      worktreeSummaries[addedPath] = .empty
      conflictStatesByWorktreePath[addedPath] = false
      refreshReviewSnapshot(for: addedPath)
      scheduleWorktreeRefresh(for: addedPath)
    }
  }

  func applyRefreshedWorktree(_ refreshedWorktree: RefreshedWorktree, for path: String) {
    let normalizedWorktreePath = normalizedPath(path)
    worktreeSummaries[normalizedWorktreePath] = refreshedWorktree.summary
    reviewTargetsByWorktreePath[normalizedWorktreePath] = refreshedWorktree.reviewTarget
    conflictStatesByWorktreePath[normalizedWorktreePath] = refreshedWorktree.hasConflicts

    guard normalizedSelectedWorktreePath == normalizedWorktreePath else { return }

    selectedSummary = refreshedWorktree.summary
    selectedFiles = refreshedWorktree.files
    selectedDiffStat = refreshedWorktree.diffStat
    selectedPullRequestURL = refreshedWorktree.pullRequestURL
    selectedReviewTarget = refreshedWorktree.reviewTarget
    selectedBranchTopology = refreshedWorktree.branchTopology
    selectedUpdatedAt = Date()
  }

  func prepareSelectionLoading(for path: String) {
    let normalizedPath = normalizedPath(path)
    selectedWorktreePath = normalizedPath
    selectedSummary = worktreeSummaries[normalizedPath] ?? .empty
    selectedFiles = []
    selectedDiffStat = ""
    selectedPullRequestURL = nil
    selectedReviewTarget = nil
    selectedBranchTopology = nil
    selectedUpdatedAt = nil
    isLoadingSelectionDetails = true
    startPendingTabRestoreIfNeeded(for: normalizedPath)
    notifyRestorableStateChanged()
  }

  func pruneTerminalState(validPaths: Set<String>) {
    let removedTabIDs =
      terminalTabsByWorktreePath
      .filter { !validPaths.contains($0.key) }
      .values
      .flatMap { $0.map(\.id) }

    for tabID in removedTabIDs {
      terminalBellTasksByTabID.removeValue(forKey: tabID)?.cancel()
      terminalAttentionVisibleClearTasksByTabID.removeValue(forKey: tabID)?.cancel()
      agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()
      GhosttyTerminalView.releaseTerminal(tabID)
    }

    terminalTabsByWorktreePath =
      terminalTabsByWorktreePath
      .filter { validPaths.contains($0.key) }
    pendingRestorableTabsByWorktreePath =
      pendingRestorableTabsByWorktreePath
      .filter { validPaths.contains($0.key) }
    pendingAgentActivitySummariesByWorktreePath =
      pendingAgentActivitySummariesByWorktreePath
      .filter { validPaths.contains($0.key) }
    selectedTerminalTabIDsByWorktreePath =
      selectedTerminalTabIDsByWorktreePath
      .filter { validPaths.contains($0.key) }
    terminalFocusRequestIDsByWorktreePath =
      terminalFocusRequestIDsByWorktreePath
      .filter { validPaths.contains($0.key) }
    let staleRestorePaths = pendingTabRestoreTasksByWorktreePath.keys.filter {
      !validPaths.contains($0)
    }
    for path in staleRestorePaths {
      pendingTabRestoreTasksByWorktreePath[path]?.cancel()
      pendingTabRestoreTasksByWorktreePath.removeValue(forKey: path)
    }
    notifyRestorableStateChanged()
  }

  func pruneWorktreeState(validPaths: Set<String>) {
    worktreeSummaries =
      worktreeSummaries
      .filter { validPaths.contains($0.key) }
    reviewTargetsByWorktreePath =
      reviewTargetsByWorktreePath
      .filter { validPaths.contains($0.key) }
    diffModesByWorktreePath =
      diffModesByWorktreePath
      .filter { validPaths.contains($0.key) }
    reviewSnapshotsByWorktreePath =
      reviewSnapshotsByWorktreePath
      .filter { validPaths.contains($0.key) }
    reviewSummaryDraftsByWorktreePath =
      reviewSummaryDraftsByWorktreePath
      .filter { validPaths.contains($0.key) }
    conflictStatesByWorktreePath =
      conflictStatesByWorktreePath
      .filter { validPaths.contains($0.key) }
    activeLocalMergeBackWorktreePaths.formIntersection(validPaths)
    completedMergeBackWorktreePaths.formIntersection(validPaths)
    pruneTerminalState(validPaths: validPaths)
  }

  func configureWatchers(validPaths: Set<String>) {
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

  func scheduleWorkspaceReload() {
    workspaceReloadTask?.cancel()
    let target = self.target
    workspaceReloadTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard let self, !Task.isCancelled else { return }

      let result = await Task.detached {
        try Self.loadDiscoveredWorktrees(target: target)
      }.result

      guard !Task.isCancelled else { return }

      switch result {
      case .success(let discoveredWorktrees):
        self.applyDiscoveredWorktreeInventory(discoveredWorktrees)
        self.errorMessage = nil
      case .failure(let error):
        self.errorMessage = error.localizedDescription
      }
    }
  }

  func scheduleWorktreeRefresh(for path: String) {
    let normalizedPath = normalizedPath(path)
    worktreeRefreshTasksByPath[normalizedPath]?.cancel()
    worktreeRefreshTasksByPath[normalizedPath] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard let self, !Task.isCancelled else { return }
      await self.refreshWorktree(path: normalizedPath)
    }
  }

  func scheduleAllWorktreeRefreshes() {
    let paths = worktrees.map { normalizedPath($0.path) }
    for path in paths {
      refreshReviewSnapshot(for: path)
      scheduleWorktreeRefresh(for: path)
    }
  }

  func refreshWorktree(path: String) async {
    let diffMode = effectiveDiffMode(for: path)
    let predictsMergeConflicts =
      worktrees.first { normalizedPath($0.path) == normalizedPath(path) }
      .map(Self.supportsAllChangesDiff(for:)) ?? false
    let result = await Task.detached {
      Self.loadRefreshedWorktree(
        for: path,
        diffMode: diffMode,
        predictsMergeConflicts: predictsMergeConflicts
      )
    }.result

    switch result {
    case .success(let refreshedWorktree):
      applyRefreshedWorktree(refreshedWorktree, for: path)
      errorMessage = nil
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }

  func slugifiedBranchName(_ branchName: String) -> String {
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

  func requestTerminalFocus(in worktreePath: String) {
    terminalFocusRequestIDsByWorktreePath[worktreePath] = UUID()
  }

  @discardableResult
  private func selectWorktree(offset: Int) -> Bool {
    guard worktrees.count > 1 else { return false }

    let selectedPath =
      normalizedSelectedWorktreePath
      ?? selectedWorktree.map { normalizedPath($0.path) }
    let currentIndex =
      selectedPath.flatMap { path in
        worktrees.firstIndex { normalizedPath($0.path) == path }
      } ?? 0
    let nextIndex = (currentIndex + offset + worktrees.count) % worktrees.count
    selectWorktree(path: worktrees[nextIndex].path)
    return true
  }

  func notifyRestorableStateChanged() {
    onRestorableStateChange?()
  }

  static func worktreeRemovalErrorMessage(
    for error: any Error,
    worktreeName: String?
  ) -> String {
    let reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedName = worktreeName?.trimmingCharacters(in: .whitespacesAndNewlines)

    let prefix =
      if let normalizedName, !normalizedName.isEmpty {
        "Argon couldn't remove \(normalizedName)."
      } else {
        "Argon couldn't remove the worktree."
      }

    guard !reason.isEmpty else {
      return prefix
    }

    return "\(prefix)\n\n\(reason)"
  }

  func resolvedInventorySelectionPath(
    preferredSelection: String,
    validPaths: Set<String>,
    previousWorktrees: [DiscoveredWorktree],
    discoveredWorktrees: [DiscoveredWorktree]
  ) -> String? {
    if validPaths.contains(preferredSelection) {
      return preferredSelection
    }

    if let nearestSelection = nearestInventorySelectionPath(
      replacing: preferredSelection,
      previousWorktrees: previousWorktrees,
      discoveredWorktrees: discoveredWorktrees
    ) {
      return nearestSelection
    }

    let normalizedRepoRoot = normalizedPath(target.repoRoot)
    if validPaths.contains(normalizedRepoRoot) {
      return normalizedRepoRoot
    }

    return discoveredWorktrees.first.map { normalizedPath($0.path) }
  }

  func nearestInventorySelectionPath(
    replacing preferredSelection: String,
    previousWorktrees: [DiscoveredWorktree],
    discoveredWorktrees: [DiscoveredWorktree]
  ) -> String? {
    guard !discoveredWorktrees.isEmpty,
      let previousIndex = previousWorktrees.firstIndex(where: {
        normalizedPath($0.path) == preferredSelection
      })
    else { return nil }

    let nearestIndex = min(previousIndex, discoveredWorktrees.count - 1)
    return normalizedPath(discoveredWorktrees[nearestIndex].path)
  }

  func clearSelectedWorktreeDetails() {
    selectedWorktreePath = nil
    selectedSummary = .empty
    selectedFiles = []
    selectedDiffStat = ""
    selectedPullRequestURL = nil
    selectedReviewTarget = nil
    selectedUpdatedAt = nil
    selectionLoadRequestID = nil
    isLoadingSelectionDetails = false
    notifyRestorableStateChanged()
  }

  func refreshReviewSnapshot(for worktreePath: String) {
    let normalizedPath = normalizedPath(worktreePath)
    let snapshots = SessionLoader.latestReviewSnapshots(forRepoRoots: [normalizedPath])
    if let snapshot = snapshots[normalizedPath] {
      reviewSnapshotsByWorktreePath[normalizedPath] = snapshot
    } else {
      reviewSnapshotsByWorktreePath.removeValue(forKey: normalizedPath)
    }
  }
}

struct RefreshedWorktree: Sendable {
  let summary: WorktreeDiffSummary
  let files: [FileDiff]
  let diffStat: String
  let pullRequestURL: String?
  let reviewTarget: ResolvedTarget?
  let branchTopology: BranchTopology?
  let hasConflicts: Bool
}

struct WorkspaceErrorDialog: Identifiable, Equatable, Sendable {
  let id = UUID()
  let title: String
  let message: String
}

struct LoadedWorkspace: Sendable {
  let worktrees: [DiscoveredWorktree]
  let worktreeSummaries: [String: WorktreeDiffSummary]
  let reviewTargetsByWorktreePath: [String: ResolvedTarget?]
  let reviewSnapshotsByWorktreePath: [String: WorkspaceReviewSnapshot]
  let conflictStatesByWorktreePath: [String: Bool]
  let selectedWorktreePath: String
  let selectedSummary: WorktreeDiffSummary
  let selectedFiles: [FileDiff]
  let selectedDiffStat: String
  let selectedPullRequestURL: String?
  let selectedReviewTarget: ResolvedTarget?
  let selectedBranchTopology: BranchTopology?
}

struct SelectionDetails: Sendable {
  let summary: WorktreeDiffSummary
  let files: [FileDiff]
  let diffStat: String
  let pullRequestURL: String?
  let reviewTarget: ResolvedTarget?
  let branchTopology: BranchTopology?
}

struct WorktreeRemovalRequest: Identifiable, Sendable {
  var id: String { worktreePath }

  let worktreePath: String
  let displayName: String
  let branchName: String?
  let hasUncommittedChanges: Bool
  let hasInitializedSubmodules: Bool
  let submodulesWithUnpushedCommits: [SubmoduleUnpushedCommits]
  let canDeleteBranch: Bool
  let branchComparisonBaseRef: String?
  let branchHasUniqueCommits: Bool
  let branchHasUnpushedCommits: Bool

  var shouldSkipConfirmation: Bool {
    !hasUncommittedChanges
      && !branchHasUniqueCommits
      && !branchHasUnpushedCommits
      && submodulesWithUnpushedCommits.isEmpty
  }

  var defaultDeletesBranch: Bool {
    canDeleteBranch
  }
}

struct WorktreeRemovalBranchDetails: Sendable {
  let hasUncommittedChanges: Bool
  let hasInitializedSubmodules: Bool
  let submodulesWithUnpushedCommits: [SubmoduleUnpushedCommits]
  let branchName: String?
  let canDeleteBranch: Bool
  let branchComparisonBaseRef: String?
  let branchHasUniqueCommits: Bool
  let branchHasUnpushedCommits: Bool
}
