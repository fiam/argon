import Foundation

@MainActor
@Observable
final class WorkspaceState {
  nonisolated(unsafe) static var tabRestoreTestDelay: Duration?
  nonisolated(unsafe) static var terminalBellFlashDuration: Duration = .seconds(1)
  nonisolated(unsafe) static var agentThinkingIdleTimeout: Duration = .seconds(1)
  nonisolated(unsafe) static var sessionRecordsProvider: (@Sendable () -> [AgentSessionRecord])?
  nonisolated(unsafe) static var commandStatusProvider: (@Sendable ([String]) -> [String: Bool])?
  nonisolated(unsafe) static var sandboxfilePromptLoader:
    (@Sendable (String, SandboxfileLaunchKind) async throws -> SandboxfilePromptRequest?) = {
      repoRoot,
      launchKind in
      try await loadSandboxfilePromptIfNeeded(repoRoot: repoRoot, launchKind: launchKind)
    }
  nonisolated(unsafe) static var sandboxfileCreator:
    (@Sendable (SandboxfilePromptRequest) async throws -> Void) = { request in
      try await createRepoSandboxfile(request: request)
    }

  var worktrees: [DiscoveredWorktree] = []
  var worktreeSummaries: [String: WorktreeDiffSummary] = [:]
  var reviewTargetsByWorktreePath: [String: ResolvedTarget?] = [:]
  var reviewSnapshotsByWorktreePath: [String: WorkspaceReviewSnapshot] = [:]
  var reviewSummaryDraftsByWorktreePath: [String: WorkspaceReviewSummaryDraft] = [:]
  var conflictStatesByWorktreePath: [String: Bool] = [:]
  var selectedWorktreePath: String?
  var selectedSummary: WorktreeDiffSummary = .empty
  var selectedFiles: [FileDiff] = []
  var selectedDiffStat = ""
  var selectedPullRequestURL: String?
  var selectedReviewTarget: ResolvedTarget?
  var selectedBranchTopology: BranchTopology?
  var selectedUpdatedAt: Date?
  var errorMessage: String?
  var launchWarningMessage: String?
  var restoreFailureMessage: String?
  var pendingShellSandboxfilePrompt: SandboxfilePromptRequest?
  var isLoadingSelectionDetails = false
  var isLoading = false
  var isLaunchingReview = false
  var isCreatingWorktree = false
  var isRemovingWorktree = false
  var isPresentingTabCreationSheet = false
  var isPresentingAgentLaunchSheet = false
  var isPresentingReviewPreparationSheet = false
  var isPresentingReviewAgentPicker = false
  var isPresentingFinalizeAgentPicker = false
  var isPresentingMergeBackOptions = false
  var reviewAgentCandidates: [WorkspaceTerminalTab] = []
  var pendingReviewPreparation: WorkspaceReviewPreparation?
  var activeReviewSummaryRequestWorktreePath: String?
  var finalizeAgentCandidates: [WorkspaceTerminalTab] = []
  var mergeBackOptions: [WorktreeFinalizeAction] = []
  var pendingReviewAgentTabID: UUID?
  var pendingFinalizeAgentTabID: UUID?
  var activeFinalizeAction: WorktreeFinalizeAction?
  var terminalTabsByWorktreePath: [String: [WorkspaceTerminalTab]] = [:]
  var selectedTerminalTabIDsByWorktreePath: [String: UUID] = [:]
  var terminalFocusRequestIDsByWorktreePath: [String: UUID] = [:]

  let target: WorkspaceTarget
  var onRestorableStateChange: (() -> Void)?
  private let worktreeRootPathProvider: () -> String

  private var commonDirWatcher: FileWatcher?
  private var worktreeWatchersByPath: [String: FileWatcher] = [:]
  private var workspaceReloadTask: Task<Void, Never>?
  private var worktreeRefreshTasksByPath: [String: Task<Void, Never>] = [:]
  private var pendingSandboxedShellLaunchCount = 0
  private var isResolvingSandboxedShellLaunch = false
  private var terminalBellTasksByTabID: [UUID: Task<Void, Never>] = [:]
  private var agentActivityIdleTasksByTabID: [UUID: Task<Void, Never>] = [:]
  private var activeAgentControlRequestsByID: [UUID: PendingWorkspaceAgentControlRequest] = [:]
  private var agentControlWatchTasksByRequestID: [UUID: Task<Void, Never>] = [:]
  private var pendingRestorableTabsByWorktreePath: [String: [PersistedWorkspaceTerminalTab]] = [:]
  private var pendingTabRestoreTasksByWorktreePath: [String: Task<Void, Never>] = [:]
  private var selectionLoadRequestID: UUID?
  private var shouldLaunchReviewAfterNextAgentTab = false
  private var pendingReviewPreparationAfterAgentLaunch: WorkspaceReviewPreparation?
  private var stagedReviewLaunch: StagedReviewLaunch?
  private var preparedReviewTargetsByAgentTabID: [UUID: ReviewTarget] = [:]
  private var didApplyUITestWebsiteDemo = false
  @ObservationIgnored
  nonisolated(unsafe) private var reviewSessionCloseObserver: NSObjectProtocol?

  init(
    target: WorkspaceTarget,
    worktreeRootPathProvider: @escaping () -> String = { WorktreeRootSettings.configuredRootPath() }
  ) {
    self.target = target
    self.worktreeRootPathProvider = worktreeRootPathProvider
    self.selectedWorktreePath = target.selectedWorktreePath ?? target.repoRoot
    self.launchWarningMessage = Self.launchWarningMessage(for: target)
    reviewSessionCloseObserver = NotificationCenter.default.addObserver(
      forName: .reviewSessionDidClose,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let repoRoot = ReviewSessionLifecycle.repoRoot(from: notification) else { return }
      Task { @MainActor [weak self] in
        self?.refreshReviewSnapshot(for: repoRoot)
      }
    }
  }

  deinit {
    if let reviewSessionCloseObserver {
      NotificationCenter.default.removeObserver(reviewSessionCloseObserver)
    }
  }

  var repoName: String {
    URL(fileURLWithPath: target.repoRoot).lastPathComponent
  }

  var selectedWorktreeLabel: String? {
    guard let selectedWorktree else { return nil }

    if let branchName = selectedWorktree.branchName?.trimmingCharacters(
      in: .whitespacesAndNewlines),
      !branchName.isEmpty
    {
      return branchName
    }

    return selectedWorktree.isDetached
      ? "Detached HEAD"
      : URL(fileURLWithPath: selectedWorktree.path).lastPathComponent
  }

  var windowTitle: String {
    guard let selectedWorktreeLabel else {
      return "Argon — \(repoName)"
    }

    return "Argon — \(repoName) — \(selectedWorktreeLabel)"
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

  var isPreparingReviewAgentLaunch: Bool {
    shouldLaunchReviewAfterNextAgentTab
  }

  var canFinalizeSelectedWorktree: Bool {
    guard let selectedWorktree, !selectedWorktree.isBaseWorktree else { return false }
    return selectedReviewTarget?.mode == .branch
  }

  var canRebaseSelectedWorktree: Bool {
    canFinalizeSelectedWorktree && (selectedBranchTopology?.needsRebase ?? false)
  }

  var canMergeBackSelectedWorktree: Bool {
    canFinalizeSelectedWorktree && ((selectedBranchTopology?.aheadCount ?? 0) > 0)
  }

  var canOpenPullRequestForSelectedWorktree: Bool {
    canFinalizeSelectedWorktree && ((selectedBranchTopology?.aheadCount ?? 0) > 0)
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
    guard let snapshot = reviewSnapshotsByWorktreePath[path] else { return nil }
    return snapshot.matches(target: reviewTargetsByWorktreePath[path] ?? nil) ? snapshot : nil
  }

  var selectedReviewSummaryText: String? {
    guard let path = normalizedSelectedWorktreePath else { return nil }
    if let draft = reviewSummaryDraftsByWorktreePath[path]?.renderedSummary, !draft.isEmpty {
      return draft
    }
    return selectedReviewSnapshot?.changeSummary
  }

  var selectedTerminalFocusRequestID: UUID? {
    guard let path = normalizedSelectedWorktreePath else { return nil }
    return terminalFocusRequestIDsByWorktreePath[path]
  }

  var canSeedFromPersistedWindowSnapshot: Bool {
    worktrees.isEmpty
      && worktreeSummaries.isEmpty
      && reviewTargetsByWorktreePath.isEmpty
      && reviewSnapshotsByWorktreePath.isEmpty
      && reviewSummaryDraftsByWorktreePath.isEmpty
      && conflictStatesByWorktreePath.isEmpty
      && terminalTabsByWorktreePath.isEmpty
      && pendingRestorableTabsByWorktreePath.isEmpty
      && pendingTabRestoreTasksByWorktreePath.isEmpty
  }

  var persistedWindowSnapshot: PersistedWorkspaceWindowSnapshot {
    let target = WorkspaceTarget(
      repoRoot: target.repoRoot,
      repoCommonDir: target.repoCommonDir,
      selectedWorktreePath: selectedWorktreePath,
      showsLinkedWorktreeWarning: false
    )

    let pendingTabsByWorktreePath = pendingRestorableTabsByWorktreePath.filter { !$0.value.isEmpty }

    let terminalTabsByWorktreePath =
      pendingTabsByWorktreePath.merging(
        terminalTabsByWorktreePath.reduce(into: [String: [PersistedWorkspaceTerminalTab]]()) {
          partialResult, entry in
          let persistedTabs = entry.value.compactMap(Self.persistedTerminalTab(from:))

          if !persistedTabs.isEmpty {
            partialResult[entry.key] = persistedTabs
          }
        }
      ) { _, materializedTabs in
        materializedTabs
      }

    let selectedTerminalTabIDsByWorktreePath = selectedTerminalTabIDsByWorktreePath.filter {
      worktreePath,
      tabID in
      terminalTabsByWorktreePath[worktreePath]?.contains(where: { $0.id == tabID }) == true
    }

    return PersistedWorkspaceWindowSnapshot(
      target: target,
      terminalTabsByWorktreePath: terminalTabsByWorktreePath,
      selectedTerminalTabIDsByWorktreePath: selectedTerminalTabIDsByWorktreePath,
      reviewSummaryDraftsByWorktreePath:
        reviewSummaryDraftsByWorktreePath
        .compactMapValues { draft in
          let normalized = draft.normalized()
          return normalized.isEmpty ? nil : normalized
        }
    )
  }

  func applyPersistedWindowSnapshot(_ snapshot: PersistedWorkspaceWindowSnapshot) {
    let resumeTemplatesByProfileName = Self.resumeTemplatesByProfileName(
      savedProfiles: SavedAgentProfiles().profiles
    )

    selectedWorktreePath = normalizedPath(snapshot.target.selectedWorktreePath ?? target.repoRoot)
    terminalTabsByWorktreePath = [:]
    pendingRestorableTabsByWorktreePath = snapshot.terminalTabsByWorktreePath.reduce(
      into: [String: [PersistedWorkspaceTerminalTab]]()
    ) { partialResult, entry in
      partialResult[normalizedPath(entry.key)] = entry.value.map { tab in
        Self.persistedTabByResolvingResumeTemplate(
          from: PersistedWorkspaceTerminalTab(
            id: tab.id,
            worktreePath: normalizedPath(tab.worktreePath),
            worktreeLabel: tab.worktreeLabel,
            title: tab.title,
            commandDescription: tab.commandDescription,
            kind: tab.kind,
            createdAt: tab.createdAt,
            isSandboxed: tab.isSandboxed,
            writableRoots: tab.writableRoots.map(normalizedPath),
            resumeArgumentTemplate: tab.resumeArgumentTemplate,
            resumeSessionID: tab.resumeSessionID,
            resumeCommandDescription: tab.resumeCommandDescription
          ),
          using: resumeTemplatesByProfileName
        )
      }
    }

    selectedTerminalTabIDsByWorktreePath = snapshot.selectedTerminalTabIDsByWorktreePath.reduce(
      into: [String: UUID]()
    ) { partialResult, entry in
      partialResult[normalizedPath(entry.key)] = entry.value
    }.filter {
      worktreePath,
      tabID in
      pendingRestorableTabsByWorktreePath[normalizedPath(worktreePath)]?.contains(where: {
        $0.id == tabID
      })
        == true
    }

    reviewSummaryDraftsByWorktreePath = snapshot.reviewSummaryDraftsByWorktreePath.reduce(
      into: [String: WorkspaceReviewSummaryDraft]()
    ) { partialResult, entry in
      let normalized = entry.value.normalized()
      if !normalized.isEmpty {
        partialResult[normalizedPath(entry.key)] = normalized
      }
    }
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
    var reviewTarget = try await Task.detached {
      try ArgonCLI.createSession(repoRoot: selectedWorktree.path, changeSummary: changeSummary)
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
      try Self.loadWorkspace(target: target, requestedSelection: normalizedPath)
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
        branchName: normalizedBranchName,
        canDeleteBranch: canDeleteBranch,
        branchComparisonBaseRef: baseRef,
        branchHasUniqueCommits:
          canDeleteBranch
          && GitService.branchHasUniqueCommits(
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
      canDeleteBranch: branchDetails.canDeleteBranch,
      branchComparisonBaseRef: branchDetails.branchComparisonBaseRef,
      branchHasUniqueCommits: branchDetails.branchHasUniqueCommits
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

  var runningAgentCount: Int {
    allTerminalTabs.reduce(into: 0) { count, tab in
      if case .agent = tab.kind, tab.isRunning {
        count += 1
      }
    }
  }

  func activeAgentCount(for worktreePath: String) -> Int {
    let tabs = terminalTabsByWorktreePath[normalizedPath(worktreePath)] ?? []
    return tabs.reduce(into: 0) { count, tab in
      if case .agent = tab.kind, tab.isRunning {
        count += 1
      }
    }
  }

  func agentActivitySummary(for worktreePath: String) -> WorktreeAgentActivitySummary {
    let tabs = terminalTabsByWorktreePath[normalizedPath(worktreePath)] ?? []
    return tabs.reduce(into: .empty) { summary, tab in
      guard case .agent = tab.kind, tab.isRunning else { return }

      summary = WorktreeAgentActivitySummary(
        waitingForHumanCount: summary.waitingForHumanCount
          + (tab.agentActivityState == .waitingForHuman ? 1 : 0),
        thinkingCount: summary.thinkingCount
          + (tab.agentActivityState == .thinking ? 1 : 0),
        runningAgentCount: summary.runningAgentCount + 1
      )
    }
  }

  func worktreeNeedsAttention(for worktreePath: String) -> Bool {
    let tabs = terminalTabsByWorktreePath[normalizedPath(worktreePath)] ?? []
    return tabs.contains { $0.hasAttention }
  }

  func defaultNewWorktreeStartPoint() -> String {
    selectedReviewTarget?.baseRef
      ?? GitService.inferBaseRef(repoRoot: target.repoRoot)
      ?? "HEAD"
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

  func presentAgentLaunchSheet(reviewAfterLaunch: Bool = false) {
    guard selectedWorktree != nil else { return }
    shouldLaunchReviewAfterNextAgentTab = reviewAfterLaunch
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
    shouldLaunchReviewAfterNextAgentTab = false
    pendingReviewPreparationAfterAgentLaunch = nil
    activeFinalizeAction = nil
    dismissMergeBackOptions()
  }

  func beginReviewLaunchFlow() {
    guard let selectedWorktree else { return }
    let worktreePath = normalizedPath(selectedWorktree.path)
    let candidates = eligibleReviewAgentTabs()
    reviewAgentCandidates = candidates
    pendingReviewPreparation = WorkspaceReviewPreparation(
      worktreePath: worktreePath,
      draft: reviewSummaryDraftsByWorktreePath[worktreePath] ?? .empty,
      selectedAgentTabID: candidates.count == 1 ? candidates[0].id : nil
    )
    isPresentingReviewPreparationSheet = true
  }

  func updatePendingReviewPreparation(_ preparation: WorkspaceReviewPreparation) {
    pendingReviewPreparation = preparation
  }

  func dismissReviewPreparationSheet() {
    isPresentingReviewPreparationSheet = false
    pendingReviewPreparation = nil
    reviewAgentCandidates = []
  }

  func isRequestingReviewSummary(for worktreePath: String) -> Bool {
    activeReviewSummaryRequestWorktreePath == normalizedPath(worktreePath)
  }

  func pendingReviewSummaryRequest(
    for worktreePath: String
  ) -> PendingWorkspaceAgentControlRequest? {
    let normalizedWorktreePath = normalizedPath(worktreePath)
    return activeAgentControlRequestsByID.values.first { pending in
      pending.worktreePath == normalizedWorktreePath && pending.request.action == .reviewSummary
    }
  }

  func launchAgentForPendingReviewPreparation() {
    guard let preparation = pendingReviewPreparation else { return }
    pendingReviewPreparationAfterAgentLaunch = preparation
    persistReviewSummaryDraft(
      preparation.draft,
      for: preparation.worktreePath
    )
    isPresentingReviewPreparationSheet = false
    pendingReviewPreparation = nil
    presentAgentLaunchSheet(reviewAfterLaunch: true)
  }

  func commitPendingReviewPreparation() -> WorkspaceReviewPreparation? {
    guard var preparation = pendingReviewPreparation else { return nil }
    preparation.draft = preparation.draft.normalized()
    persistReviewSummaryDraft(preparation.draft, for: preparation.worktreePath)
    isPresentingReviewPreparationSheet = false
    pendingReviewPreparation = nil
    reviewAgentCandidates = []
    return preparation
  }

  func prepareReviewSummaryPrompt(
    for worktreePath: String,
    agentTabID: UUID?
  ) throws -> String {
    let request = try reviewSummaryControlRequest(for: worktreePath)
    let pendingRequest = try beginAgentControlRequest(
      request,
      worktreePath: worktreePath,
      sourceTabID: agentTabID
    )
    activeReviewSummaryRequestWorktreePath = normalizedPath(worktreePath)
    return try request.promptWithResponseContract(responseFilePath: pendingRequest.responseFilePath)
  }

  func cancelReviewSummaryRequest(for worktreePath: String) {
    cancelConflictingAgentControlRequests(
      for: normalizedPath(worktreePath),
      action: .reviewSummary
    )
  }

  func beginRebaseFlow() {
    guard canRebaseSelectedWorktree else { return }
    beginFinalizeFlow(.rebaseOntoBase)
  }

  func beginMergeBackFlow() {
    guard canMergeBackSelectedWorktree, let selectedBranchTopology else { return }

    if selectedBranchTopology.canFastForwardBase && selectedBranchTopology.aheadCount == 1 {
      beginFinalizeFlow(.fastForwardToBase)
      return
    }

    let options = mergeBackOptions(for: selectedBranchTopology)
    guard !options.isEmpty else { return }

    if options.count == 1 {
      beginFinalizeFlow(options[0])
      return
    }

    mergeBackOptions = options
    isPresentingMergeBackOptions = true
  }

  func chooseMergeBackAction(_ action: WorktreeFinalizeAction) {
    dismissMergeBackOptions()
    beginFinalizeFlow(action)
  }

  func dismissMergeBackOptions() {
    isPresentingMergeBackOptions = false
    mergeBackOptions = []
  }

  func beginOpenPullRequestFlow() {
    guard canOpenPullRequestForSelectedWorktree else { return }
    beginFinalizeFlow(.openPullRequest)
  }

  func beginFinalizeFlow(_ action: WorktreeFinalizeAction) {
    guard selectedWorktree != nil else { return }

    dismissMergeBackOptions()
    activeFinalizeAction = action
    let candidates = eligibleFinalizeAgentTabs(for: action)

    switch candidates.count {
    case 0:
      presentAgentLaunchSheet()
    case 1:
      pendingFinalizeAgentTabID = candidates[0].id
    default:
      finalizeAgentCandidates = candidates
      isPresentingFinalizeAgentPicker = true
    }
  }

  func chooseReviewAgentTab(_ tabID: UUID) {
    pendingReviewAgentTabID = tabID
    dismissReviewAgentPicker()
  }

  func dismissReviewAgentPicker() {
    isPresentingReviewAgentPicker = false
    reviewAgentCandidates = []
  }

  func chooseFinalizeAgentTab(_ tabID: UUID) {
    pendingFinalizeAgentTabID = tabID
    dismissFinalizeAgentPicker(resetAction: false)
  }

  func dismissFinalizeAgentPicker(resetAction: Bool = true) {
    isPresentingFinalizeAgentPicker = false
    finalizeAgentCandidates = []
    if resetAction {
      activeFinalizeAction = nil
    }
  }

  func finishFinalizeFlow() {
    pendingFinalizeAgentTabID = nil
    finalizeAgentCandidates = []
    isPresentingFinalizeAgentPicker = false
    activeFinalizeAction = nil
    dismissMergeBackOptions()
  }

  func launchAgent(using options: WorkspaceAgentLaunchOptions) async throws {
    guard shouldLaunchReviewAfterNextAgentTab else {
      if let finalizeAction = activeFinalizeAction {
        let prompt = try prepareFinalizePrompt(for: finalizeAction, sourceTabID: nil)
        let additionalWritableRoots =
          finalizeAction.requiresBaseRepoWriteAccess ? [target.repoRoot] : []
        guard
          openAgentTab(
            options.buildRequest(
              prompt: prompt,
              additionalWritableRoots: additionalWritableRoots
            ))
            != nil
        else {
          throw GitService.GitError.commandFailed(
            "Open a worktree before launching a finalize agent."
          )
        }
        finishFinalizeFlow()
        return
      }

      _ = openAgentTab(options.buildRequest())
      return
    }

    let changeSummary = pendingReviewPreparationAfterAgentLaunch?.draft.renderedSummary
    let target = try await createReviewTarget(
      launchContext: .coderHandoff,
      changeSummary: changeSummary
    )

    do {
      let prompt = try await Task.detached {
        try ArgonCLI.agentPrompt(sessionId: target.sessionId, repoRoot: target.repoRoot)
      }.value

      guard let tab = openAgentTab(options.buildRequest(prompt: prompt)) else {
        throw GitService.GitError.commandFailed("Open a worktree before launching a review agent.")
      }

      stageReviewLaunch(target: target, agentTabID: tab.id)
      shouldLaunchReviewAfterNextAgentTab = false
      pendingReviewPreparationAfterAgentLaunch = nil
    } catch {
      try? await Task.detached {
        try ArgonCLI.closeSession(sessionId: target.sessionId, repoRoot: target.repoRoot)
      }.value
      refreshReviewSnapshot(for: target.repoRoot)
      pendingReviewPreparationAfterAgentLaunch = nil
      throw error
    }
  }

  func activateStagedReviewLaunch() {
    guard let stagedReviewLaunch else { return }
    preparedReviewTargetsByAgentTabID[stagedReviewLaunch.agentTabID] = stagedReviewLaunch.target
    pendingReviewAgentTabID = stagedReviewLaunch.agentTabID
    self.stagedReviewLaunch = nil
  }

  func consumePreparedReviewTarget(for agentTabID: UUID) -> ReviewTarget? {
    preparedReviewTargetsByAgentTabID.removeValue(forKey: agentTabID)
  }

  func openShellTab(sandboxed: Bool = true) {
    guard let worktree = selectedWorktree else { return }

    let worktreePath = normalizedPath(worktree.path)
    let ordinal = nextOrdinal(in: worktreePath) { tab in
      if case .shell = tab.kind {
        return tab.isSandboxed == sandboxed
      }
      return false
    }

    let tabID = UUID()
    let tab = WorkspaceTerminalTab(
      id: tabID,
      worktreePath: worktreePath,
      worktreeLabel: worktree.branchName ?? repoName,
      title: sandboxed ? "Shell \(ordinal)" : "Privileged Shell \(ordinal)",
      commandDescription: sandboxed
        ? "Sandboxed \(UserShell.resolvedPath())"
        : UserShell
          .resolvedPath(),
      kind: .shell,
      launch: sandboxed
        ? TerminalLaunchConfiguration.sandboxedShell(
          currentDirectory: worktree.path,
          writableRoots: [worktree.path],
          tabID: tabID
        )
        : TerminalLaunchConfiguration.shell(currentDirectory: worktree.path, tabID: tabID),
      isSandboxed: sandboxed,
      writableRoots: sandboxed ? [normalizedPath(worktree.path)] : [],
      isRestorableAfterRelaunch: true
    )

    insertTerminalTab(tab, for: worktreePath)
  }

  func applyUITestWebsiteDemoIfNeeded() {
    let config = UITestAutomationConfig.current()
    guard config.websiteDemoEnabled, !didApplyUITestWebsiteDemo else { return }
    guard !worktrees.isEmpty, selectedWorktree != nil else { return }

    didApplyUITestWebsiteDemo = true
    configureUITestWebsiteDemo(useLiveAgentCommands: config.websiteDemoUsesLiveAgentCommands)
  }

  func requestSandboxedShellLaunch() {
    pendingSandboxedShellLaunchCount += 1
    guard pendingShellSandboxfilePrompt == nil, !isResolvingSandboxedShellLaunch else { return }
    isResolvingSandboxedShellLaunch = true

    Task { @MainActor in
      defer { isResolvingSandboxedShellLaunch = false }
      do {
        if let prompt = try await Self.sandboxfilePromptLoader(target.repoRoot, .shell) {
          pendingShellSandboxfilePrompt = prompt
          return
        }
        let launchCount = pendingSandboxedShellLaunchCount
        pendingSandboxedShellLaunchCount = 0
        for _ in 0..<launchCount {
          openShellTab()
        }
      } catch {
        pendingSandboxedShellLaunchCount = 0
        errorMessage = error.localizedDescription
      }
    }
  }

  func dismissShellSandboxfilePrompt() {
    pendingShellSandboxfilePrompt = nil
    pendingSandboxedShellLaunchCount = 0
  }

  func confirmSandboxedShellLaunch() {
    guard let prompt = pendingShellSandboxfilePrompt else { return }
    let launchCount = max(pendingSandboxedShellLaunchCount, 1)
    pendingShellSandboxfilePrompt = nil
    pendingSandboxedShellLaunchCount = 0

    Task { @MainActor in
      do {
        try await Self.sandboxfileCreator(prompt)
        for _ in 0..<launchCount {
          openShellTab()
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  @discardableResult
  func openAgentTab(_ request: WorkspaceAgentLaunchRequest) -> WorkspaceTerminalTab? {
    guard let worktree = selectedWorktree else { return nil }

    let worktreePath = normalizedPath(worktree.path)
    let ordinal = nextOrdinal(in: worktreePath) { tab in
      if case .agent(let profileName, _) = tab.kind {
        return profileName == request.displayName
      }
      return false
    }

    let writableRoots =
      request.sandboxEnabled
      ? uniqueWritableRoots(
        primaryRoot: worktree.path,
        additionalRoots: request.additionalWritableRoots
      )
      : []
    let tabID = UUID()
    let launch =
      request.sandboxEnabled
      ? TerminalLaunchConfiguration.sandboxedCommand(
        request.command,
        currentDirectory: worktree.path,
        writableRoots: writableRoots,
        launchKind: "agent",
        agentFamily: sandboxAgentFamily(from: request.command),
        tabID: tabID
      )
      : TerminalLaunchConfiguration.command(
        request.command,
        currentDirectory: worktree.path,
        tabID: tabID
      )
    let resumeArgumentTemplate =
      request.isRestorableAfterRelaunch
      ? request.resumeArgumentTemplate
      : ""
    let resumeCommandDescription = renderAgentResumeCommand(
      baseCommand: request.command,
      resumeArgumentTemplate: resumeArgumentTemplate,
      sessionID: nil
    )

    let tab = WorkspaceTerminalTab(
      id: tabID,
      worktreePath: worktreePath,
      worktreeLabel: worktree.branchName ?? repoName,
      title: agentTabTitle(for: request, ordinal: ordinal),
      commandDescription: request.command,
      kind: .agent(profileName: request.displayName, icon: request.icon),
      launch: launch,
      isSandboxed: request.sandboxEnabled,
      writableRoots: writableRoots.map(normalizedPath),
      isRestorableAfterRelaunch: request.isRestorableAfterRelaunch,
      resumeArgumentTemplate: resumeArgumentTemplate,
      resumeSessionID: nil,
      resumeCommandDescription: resumeCommandDescription
    )

    insertTerminalTab(tab, for: worktreePath)
    return tab
  }

  func selectTerminalTab(_ tabID: UUID) {
    guard let worktreePath = normalizedSelectedWorktreePath else { return }
    guard let tab = terminalTabsByWorktreePath[worktreePath]?.first(where: { $0.id == tabID })
    else { return }
    selectedTerminalTabIDsByWorktreePath[worktreePath] = tabID
    tab.hasAttention = false
    clearAgentWaitingForHuman(tabID)
    requestTerminalFocus(in: worktreePath)
    notifyRestorableStateChanged()
  }

  @discardableResult
  func focusTerminal(tabID: UUID, in worktreePath: String) -> Bool {
    let normalizedWorktreePath = normalizedPath(worktreePath)
    guard
      terminalTabsByWorktreePath[normalizedWorktreePath]?.contains(where: { $0.id == tabID })
        == true
    else {
      return false
    }
    if normalizedSelectedWorktreePath != normalizedWorktreePath {
      selectWorktree(path: normalizedWorktreePath)
    }
    selectedTerminalTabIDsByWorktreePath[normalizedWorktreePath] = tabID
    if let tab = terminalTab(for: tabID) {
      tab.hasAttention = false
    }
    clearAgentWaitingForHuman(tabID)
    requestTerminalFocus(in: normalizedWorktreePath)
    notifyRestorableStateChanged()
    return true
  }

  func markTerminalNeedsAttention(_ tabID: UUID) {
    guard let tab = terminalTab(for: tabID) else { return }
    guard !tab.hasAttention else { return }
    tab.hasAttention = true
    notifyRestorableStateChanged()
  }

  func recordTerminalTitleChange(_ title: String, for tabID: UUID) {
    guard let tab = terminalTab(for: tabID), tab.isRunning else { return }
    guard case .agent = tab.kind else { return }

    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTitle.isEmpty else {
      tab.lastObservedTerminalTitle = nil
      agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()
      if tab.agentActivityState == .thinking {
        tab.agentActivityState = .idle
      }
      return
    }

    guard tab.lastObservedTerminalTitle != normalizedTitle else { return }
    tab.lastObservedTerminalTitle = normalizedTitle
    tab.agentActivityState = .thinking
    scheduleAgentActivityIdle(tabID)
  }

  func markAgentWaitingForHuman(_ tabID: UUID) {
    guard let tab = terminalTab(for: tabID), tab.isRunning else { return }
    guard case .agent = tab.kind else { return }

    agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()
    tab.agentActivityState = .waitingForHuman
  }

  func flashTerminalBell(_ tabID: UUID) {
    guard let tab = terminalTab(for: tabID) else { return }

    terminalBellTasksByTabID.removeValue(forKey: tabID)?.cancel()
    tab.isShowingBellIndicator = true

    let flashDuration = Self.terminalBellFlashDuration
    terminalBellTasksByTabID[tabID] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: flashDuration)
      } catch {
        return
      }

      guard let self else { return }
      self.terminalBellTasksByTabID.removeValue(forKey: tabID)
      self.terminalTab(for: tabID)?.isShowingBellIndicator = false
    }
  }

  private func scheduleAgentActivityIdle(_ tabID: UUID) {
    agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()

    let timeout = Self.agentThinkingIdleTimeout
    agentActivityIdleTasksByTabID[tabID] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }

      guard let self else { return }
      self.agentActivityIdleTasksByTabID.removeValue(forKey: tabID)

      guard let tab = self.terminalTab(for: tabID), tab.agentActivityState == .thinking else {
        return
      }
      tab.agentActivityState = .idle
    }
  }

  private func clearAgentWaitingForHuman(_ tabID: UUID) {
    guard let tab = terminalTab(for: tabID), tab.agentActivityState == .waitingForHuman else {
      return
    }
    tab.agentActivityState = .idle
  }

  func closeTerminalTab(_ tabID: UUID) {
    terminalBellTasksByTabID.removeValue(forKey: tabID)?.cancel()
    agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()

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
      GhosttyTerminalView.releaseTerminal(tabID)
      notifyRestorableStateChanged()
      return
    }
  }

  func handleTerminalExit(_ tabID: UUID, exitBehavior: WorkspaceFinishedTerminalBehavior) {
    guard let tab = terminalTab(for: tabID) else { return }
    agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()
    tab.isRunning = false
    tab.agentActivityState = .idle

    guard exitBehavior == .autoClose else { return }

    Task { @MainActor [weak self] in
      self?.closeTerminalTab(tabID)
    }
  }

  private func loadSelectedWorktreeDetails(for path: String) {
    let requestID = UUID()
    selectionLoadRequestID = requestID

    Task {
      let result = await Task.detached {
        Self.loadSelectionDetails(for: path)
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

  nonisolated private static func loadWorkspace(
    target: WorkspaceTarget,
    requestedSelection: String
  ) throws -> LoadedWorkspace {
    let worktrees = try loadDiscoveredWorktrees(target: target)
    let normalizedPaths = Set(worktrees.map { normalizedPath($0.path) })
    let worktreeSummaries = Dictionary(
      uniqueKeysWithValues: worktrees.map { worktree in
        let normalized = normalizedPath(worktree.path)
        return (normalized, GitService.diffSummary(repoRoot: worktree.path))
      }
    )
    let reviewTargetsByWorktreePath = Dictionary(
      uniqueKeysWithValues: worktrees.map { worktree in
        let normalized = normalizedPath(worktree.path)
        return (normalized, GitService.autoDetectTarget(repoRoot: worktree.path))
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

  nonisolated private static func loadDiscoveredWorktrees(target: WorkspaceTarget) throws
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

  nonisolated private static func loadSelectionDetails(
    for path: String,
    summary: WorktreeDiffSummary? = nil
  ) -> SelectionDetails {
    let files = GitService.diffFiles(repoRoot: path)
    let reviewTarget = GitService.autoDetectTarget(repoRoot: path)
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

  nonisolated private static func loadRefreshedWorktree(for path: String) -> RefreshedWorktree {
    let details = loadSelectionDetails(for: path)
    return RefreshedWorktree(
      summary: details.summary,
      files: details.files,
      diffStat: details.diffStat,
      pullRequestURL: details.pullRequestURL,
      reviewTarget: details.reviewTarget,
      branchTopology: details.branchTopology,
      hasConflicts: GitService.hasConflicts(repoRoot: path)
    )
  }

  nonisolated private static func restorePersistedTabs(
    _ persistedTabs: [PersistedWorkspaceTerminalTab]
  ) -> RestoredPersistedTabs {
    let hydratedTabs = hydratedPersistedAgentResumeMetadata(for: persistedTabs)

    let agentCommands: [String] = hydratedTabs.compactMap { persistedTab in
      guard case .agent = persistedTab.kind else { return nil }
      return commandExecutableToken(
        from: persistedTab.resumeCommandDescription ?? persistedTab.commandDescription
      )
    }
    let commandStatuses =
      Self.commandStatusProvider?(agentCommands)
      ?? UserShell.loginCommandStatuses(agentCommands)

    var restorableTabs: [PersistedWorkspaceTerminalTab] = []
    var missingAgentCount = 0

    for persistedTab in hydratedTabs {
      if case .agent = persistedTab.kind {
        let executable = commandExecutableToken(
          from: persistedTab.resumeCommandDescription ?? persistedTab.commandDescription
        )
        guard commandStatuses[executable] == true else {
          missingAgentCount += 1
          continue
        }
      }

      restorableTabs.append(persistedTab)
    }

    return RestoredPersistedTabs(
      persistedTabs: restorableTabs,
      missingAgentCount: missingAgentCount
    )
  }

  private static func restoredTerminalTab(
    from persistedTab: PersistedWorkspaceTerminalTab
  ) -> WorkspaceTerminalTab {
    let launch: TerminalLaunchConfiguration
    let kind: WorkspaceTerminalKind
    let launchCommandDescription =
      persistedTab.resumeCommandDescription ?? persistedTab.commandDescription

    switch persistedTab.kind {
    case .shell:
      kind = .shell
      launch =
        persistedTab.isSandboxed
        ? TerminalLaunchConfiguration.sandboxedShell(
          currentDirectory: persistedTab.worktreePath,
          writableRoots: persistedTab.writableRoots,
          tabID: persistedTab.id
        )
        : TerminalLaunchConfiguration.shell(
          currentDirectory: persistedTab.worktreePath,
          tabID: persistedTab.id
        )
    case .agent(let profileName, let icon):
      kind = .agent(profileName: profileName, icon: icon)
      launch =
        persistedTab.isSandboxed
        ? TerminalLaunchConfiguration.sandboxedCommand(
          launchCommandDescription,
          currentDirectory: persistedTab.worktreePath,
          writableRoots: persistedTab.writableRoots,
          launchKind: "agent",
          agentFamily: sandboxAgentFamily(from: launchCommandDescription),
          tabID: persistedTab.id
        )
        : TerminalLaunchConfiguration.command(
          launchCommandDescription,
          currentDirectory: persistedTab.worktreePath,
          tabID: persistedTab.id
        )
    }

    return WorkspaceTerminalTab(
      id: persistedTab.id,
      worktreePath: persistedTab.worktreePath,
      worktreeLabel: persistedTab.worktreeLabel,
      title: persistedTab.title,
      commandDescription: persistedTab.commandDescription,
      kind: kind,
      launch: launch,
      createdAt: persistedTab.createdAt,
      isSandboxed: persistedTab.isSandboxed,
      writableRoots: persistedTab.writableRoots,
      isRestorableAfterRelaunch: true,
      resumeArgumentTemplate: persistedTab.resumeArgumentTemplate,
      resumeSessionID: persistedTab.resumeSessionID,
      resumeCommandDescription: persistedTab.resumeCommandDescription
    )
  }

  nonisolated private static func hydratedPersistedAgentResumeMetadata(
    for persistedTabs: [PersistedWorkspaceTerminalTab]
  ) -> [PersistedWorkspaceTerminalTab] {
    var hydratedTabs = persistedTabs

    for index in hydratedTabs.indices {
      let tab = hydratedTabs[index]
      guard case .agent = tab.kind else { continue }
      guard tab.resumeCommandDescription == nil else { continue }
      guard
        let renderedResumeCommand = renderAgentResumeCommand(
          baseCommand: tab.commandDescription,
          resumeArgumentTemplate: tab.resumeArgumentTemplate,
          sessionID: tab.resumeSessionID
        )
      else { continue }
      hydratedTabs[index] = PersistedWorkspaceTerminalTab(
        id: tab.id,
        worktreePath: tab.worktreePath,
        worktreeLabel: tab.worktreeLabel,
        title: tab.title,
        commandDescription: tab.commandDescription,
        kind: tab.kind,
        createdAt: tab.createdAt,
        isSandboxed: tab.isSandboxed,
        writableRoots: tab.writableRoots,
        resumeArgumentTemplate: tab.resumeArgumentTemplate,
        resumeSessionID: tab.resumeSessionID,
        resumeCommandDescription: renderedResumeCommand
      )
    }

    let unresolvedGroups = Dictionary(
      grouping: hydratedTabs.indices.filter { index in
        let tab = hydratedTabs[index]
        guard case .agent = tab.kind else { return false }
        guard tab.resumeCommandDescription == nil else { return false }
        guard tab.resumeArgumentTemplate.contains("{{session_id}}") else { return false }
        return isCodexCommand(tab.commandDescription)
      }
    ) { index in
      normalizedPath(hydratedTabs[index].worktreePath)
    }

    guard !unresolvedGroups.isEmpty else { return hydratedTabs }

    let earliestCreatedAt =
      unresolvedGroups.values
      .flatMap { $0 }
      .compactMap { hydratedTabs[$0].createdAt }
      .min()
      ?? .distantPast
    let codexSessionsByWorktreePath = groupedCodexSessions(
      notBefore: earliestCreatedAt.addingTimeInterval(-3600)
    )

    for (worktreePath, indices) in unresolvedGroups {
      guard !indices.isEmpty else { continue }
      guard var sessions = codexSessionsByWorktreePath[worktreePath], !sessions.isEmpty else {
        continue
      }

      sessions.sort {
        if $0.startedAt == $1.startedAt {
          return $0.sessionID < $1.sessionID
        }
        return $0.startedAt < $1.startedAt
      }

      let existingSessionIDs: Set<String> = Set(
        hydratedTabs.compactMap { tab in
          let normalizedTabWorktreePath = normalizedPath(tab.worktreePath)
          guard normalizedTabWorktreePath == worktreePath else { return nil }
          return tab.resumeSessionID
        }
      )
      var usedSessionIDs = existingSessionIDs

      let sortedIndices = indices.sorted {
        let lhs = hydratedTabs[$0]
        let rhs = hydratedTabs[$1]
        if lhs.createdAt == rhs.createdAt {
          return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
      }

      for index in sortedIndices {
        let tab = hydratedTabs[index]
        if let tabSessionID = tab.resumeSessionID, !tabSessionID.isEmpty {
          usedSessionIDs.insert(tabSessionID)
          if let renderedResumeCommand = renderAgentResumeCommand(
            baseCommand: tab.commandDescription,
            resumeArgumentTemplate: tab.resumeArgumentTemplate,
            sessionID: tabSessionID
          ) {
            hydratedTabs[index] = PersistedWorkspaceTerminalTab(
              id: tab.id,
              worktreePath: tab.worktreePath,
              worktreeLabel: tab.worktreeLabel,
              title: tab.title,
              commandDescription: tab.commandDescription,
              kind: tab.kind,
              createdAt: tab.createdAt,
              isSandboxed: tab.isSandboxed,
              writableRoots: tab.writableRoots,
              resumeArgumentTemplate: tab.resumeArgumentTemplate,
              resumeSessionID: tabSessionID,
              resumeCommandDescription: renderedResumeCommand
            )
          }
          continue
        }

        let createdAtCutoff = tab.createdAt.addingTimeInterval(-120)
        let matchingSession =
          sessions.first { session in
            !usedSessionIDs.contains(session.sessionID) && session.startedAt >= createdAtCutoff
          }
          ?? sessions.first { session in
            !usedSessionIDs.contains(session.sessionID)
          }

        guard let matchingSession else { continue }
        usedSessionIDs.insert(matchingSession.sessionID)
        guard
          let renderedResumeCommand = renderAgentResumeCommand(
            baseCommand: tab.commandDescription,
            resumeArgumentTemplate: tab.resumeArgumentTemplate,
            sessionID: matchingSession.sessionID
          )
        else { continue }

        hydratedTabs[index] = PersistedWorkspaceTerminalTab(
          id: tab.id,
          worktreePath: tab.worktreePath,
          worktreeLabel: tab.worktreeLabel,
          title: tab.title,
          commandDescription: tab.commandDescription,
          kind: tab.kind,
          createdAt: tab.createdAt,
          isSandboxed: tab.isSandboxed,
          writableRoots: tab.writableRoots,
          resumeArgumentTemplate: tab.resumeArgumentTemplate,
          resumeSessionID: matchingSession.sessionID,
          resumeCommandDescription: renderedResumeCommand
        )
      }
    }

    return hydratedTabs
  }

  nonisolated private static func groupedCodexSessions(notBefore: Date) -> [String:
    [CodexSessionRecord]]
  {
    let records = loadCodexSessionRecords(notBefore: notBefore)
    return Dictionary(grouping: records) { record in
      normalizedPath(record.cwd)
    }
  }

  nonisolated private static func loadCodexSessionRecords(notBefore: Date) -> [CodexSessionRecord] {
    if let provider = sessionRecordsProvider {
      return provider()
        .filter { $0.provider == .codex && $0.startedAt >= notBefore }
        .map {
          CodexSessionRecord(sessionID: $0.sessionID, cwd: $0.cwd, startedAt: $0.startedAt)
        }
    }

    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }

    let keys: Set<URLResourceKey> = [.isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    var records: [CodexSessionRecord] = []
    for case let fileURL as URL in enumerator {
      guard fileURL.pathExtension == "jsonl" else { continue }
      guard fileURL.lastPathComponent.hasPrefix("rollout-") else { continue }
      guard
        let values = try? fileURL.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else {
        continue
      }
      guard
        let metadata = codexSessionMetadataFromRolloutFilename(fileURL.lastPathComponent)
      else {
        continue
      }
      let startedAt = metadata.startedAt ?? .distantPast
      guard startedAt >= notBefore else { continue }
      guard let prefix = try? readUTF8Prefix(of: fileURL, maxBytes: 4096) else { continue }
      guard let cwd = jsonStringValue(forKey: "cwd", in: prefix), !cwd.isEmpty else { continue }
      records.append(
        CodexSessionRecord(sessionID: metadata.sessionID, cwd: cwd, startedAt: startedAt)
      )
    }

    return records
  }

  nonisolated private static func readUTF8Prefix(of url: URL, maxBytes: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  nonisolated private static func codexSessionMetadataFromRolloutFilename(_ filename: String)
    -> (sessionID: String, startedAt: Date?)?
  {
    guard filename.hasPrefix("rollout-"), filename.hasSuffix(".jsonl") else { return nil }
    let stem = filename.dropFirst("rollout-".count).dropLast(".jsonl".count)
    let timestampLength = 19  // yyyy-MM-dd'T'HH-mm-ss
    guard stem.count > timestampLength else {
      return nil
    }
    let separatorIndex = stem.index(stem.startIndex, offsetBy: timestampLength)
    guard stem[separatorIndex] == "-" else { return nil }

    let timestampText = String(stem[..<separatorIndex])
    let sessionStart = parseCodexRolloutTimestamp(timestampText)

    let sessionIDStart = stem.index(after: separatorIndex)
    let sessionID = String(stem[sessionIDStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else {
      return nil
    }
    return (sessionID, sessionStart)
  }

  nonisolated private static func parseCodexRolloutTimestamp(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    return formatter.date(from: value)
  }

  nonisolated private static func jsonStringValue(forKey key: String, in text: String) -> String? {
    let token = "\"\(key)\":\""
    guard let tokenRange = text.range(of: token) else { return nil }
    var index = tokenRange.upperBound
    var escaped = false
    var characters: [Character] = []

    while index < text.endIndex {
      let character = text[index]
      if escaped {
        characters.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        let raw = String(characters)
        return raw.replacingOccurrences(of: "\\/", with: "/")
      } else {
        characters.append(character)
      }
      index = text.index(after: index)
    }

    return nil
  }

  nonisolated private static func isCodexCommand(_ command: String) -> Bool {
    commandExecutableName(from: command).lowercased() == "codex"
  }

  private static func persistedTerminalTab(from tab: WorkspaceTerminalTab)
    -> PersistedWorkspaceTerminalTab?
  {
    guard tab.isRunning, tab.isRestorableAfterRelaunch else { return nil }

    let kind: PersistedWorkspaceTerminalTabKind
    switch tab.kind {
    case .shell:
      kind = .shell
    case .agent(let profileName, let icon):
      kind = .agent(profileName: profileName, icon: icon)
    }

    return PersistedWorkspaceTerminalTab(
      id: tab.id,
      worktreePath: tab.worktreePath,
      worktreeLabel: tab.worktreeLabel,
      title: tab.title,
      commandDescription: tab.commandDescription,
      kind: kind,
      createdAt: tab.createdAt,
      isSandboxed: tab.isSandboxed,
      writableRoots: tab.writableRoots,
      resumeArgumentTemplate: tab.resumeArgumentTemplate,
      resumeSessionID: tab.resumeSessionID,
      resumeCommandDescription: tab.resumeCommandDescription
    )
  }

  nonisolated private static func persistedTabByResolvingResumeTemplate(
    from tab: PersistedWorkspaceTerminalTab,
    using resumeTemplatesByProfileName: [String: String]
  ) -> PersistedWorkspaceTerminalTab {
    guard case .agent(let profileName, _) = tab.kind else { return tab }
    let resumeArgumentTemplate = resumeTemplatesByProfileName[profileName] ?? ""
    guard resumeArgumentTemplate != tab.resumeArgumentTemplate else { return tab }

    return PersistedWorkspaceTerminalTab(
      id: tab.id,
      worktreePath: tab.worktreePath,
      worktreeLabel: tab.worktreeLabel,
      title: tab.title,
      commandDescription: tab.commandDescription,
      kind: tab.kind,
      createdAt: tab.createdAt,
      isSandboxed: tab.isSandboxed,
      writableRoots: tab.writableRoots,
      resumeArgumentTemplate: resumeArgumentTemplate,
      resumeSessionID: tab.resumeSessionID,
      resumeCommandDescription: tab.resumeCommandDescription
    )
  }

  private static func resumeTemplatesByProfileName(savedProfiles: [SavedAgentProfile])
    -> [String: String]
  {
    var templates: [String: String] = [:]

    for profile in SavedAgentProfiles.builtinDefaults where !profile.resumeArgumentTemplate.isEmpty
    {
      templates[profile.name] = profile.resumeArgumentTemplate
    }

    for profile in savedProfiles where !profile.resumeArgumentTemplate.isEmpty {
      templates[profile.name] = profile.resumeArgumentTemplate
    }

    return templates
  }

  nonisolated private static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  nonisolated private static func launchWarningMessage(for target: WorkspaceTarget) -> String? {
    guard target.showsLinkedWorktreeWarning else { return nil }
    guard let selectedWorktreePath = target.selectedWorktreePath else { return nil }

    let normalizedRepoRoot = normalizedPath(target.repoRoot)
    let normalizedWorktreePath = normalizedPath(selectedWorktreePath)
    guard normalizedRepoRoot != normalizedWorktreePath else { return nil }

    return
      "Opened the original repository at \(normalizedRepoRoot) because \(normalizedWorktreePath) is a linked worktree."
  }

  nonisolated private static func formattedRestoreFailureMessage(
    missingAgentCount: Int,
    worktreeLabel: String
  ) -> String {
    let noun = missingAgentCount == 1 ? "agent tab" : "agent tabs"
    let availability = missingAgentCount == 1 ? "its command is" : "their commands are"
    return
      "\(missingAgentCount) \(noun) couldn’t be restored for \(worktreeLabel) because \(availability) no longer available."
  }

  private func normalizedPath(_ path: String) -> String {
    Self.normalizedPath(path)
  }

  private func applyLoadedWorkspace(_ data: LoadedWorkspace) {
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
    startPendingTabRestoreIfNeeded(for: normalizedPath(data.selectedWorktreePath))
    notifyRestorableStateChanged()
  }

  func applyDiscoveredWorktreeInventory(_ discoveredWorktrees: [DiscoveredWorktree]) {
    guard
      Self.shouldReloadWorktreeInventory(
        currentWorktrees: worktrees,
        discoveredWorktrees: discoveredWorktrees
      )
    else {
      scheduleAllWorktreeRefreshes()
      return
    }

    let currentPaths = Set(worktrees.map { normalizedPath($0.path) })
    let validPaths = Set(discoveredWorktrees.map { normalizedPath($0.path) })
    let addedPaths = validPaths.subtracting(currentPaths)
    let preservedSelection = normalizedSelectedWorktreePath
    let preferredSelection =
      preservedSelection ?? normalizedPath(target.selectedWorktreePath ?? target.repoRoot)

    worktrees = discoveredWorktrees
    pruneWorktreeState(validPaths: validPaths)
    configureWatchers(validPaths: validPaths)

    if let nextSelection = resolvedInventorySelectionPath(
      preferredSelection: preferredSelection,
      validPaths: validPaths
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
    worktreeSummaries[path] = refreshedWorktree.summary
    reviewTargetsByWorktreePath[path] = refreshedWorktree.reviewTarget
    conflictStatesByWorktreePath[path] = refreshedWorktree.hasConflicts

    guard normalizedSelectedWorktreePath == path else { return }

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

  private func startPendingTabRestoreIfNeeded(for worktreePath: String) {
    let normalizedPath = normalizedPath(worktreePath)
    guard pendingTabRestoreTasksByWorktreePath[normalizedPath] == nil,
      let persistedTabs = pendingRestorableTabsByWorktreePath.removeValue(forKey: normalizedPath),
      !persistedTabs.isEmpty
    else {
      return
    }

    pendingTabRestoreTasksByWorktreePath[normalizedPath] = Task { @MainActor [weak self] in
      if let delay = Self.tabRestoreTestDelay {
        try? await Task.sleep(for: delay)
      }
      let restored = await Task.detached {
        Self.restorePersistedTabs(persistedTabs)
      }.value

      guard let self, !Task.isCancelled else { return }
      self.pendingTabRestoreTasksByWorktreePath.removeValue(forKey: normalizedPath)
      let restoredTabs = restored.persistedTabs.map(Self.restoredTerminalTab(from:))
      let currentTabs = self.terminalTabsByWorktreePath[normalizedPath] ?? []
      let currentTabsByID = Dictionary(uniqueKeysWithValues: currentTabs.map { ($0.id, $0) })
      var mergedTabs: [WorkspaceTerminalTab] = []
      var seenTabIDs = Set<UUID>()

      for restoredTab in restoredTabs {
        let tab = currentTabsByID[restoredTab.id] ?? restoredTab
        guard seenTabIDs.insert(tab.id).inserted else { continue }
        mergedTabs.append(tab)
      }

      for currentTab in currentTabs where seenTabIDs.insert(currentTab.id).inserted {
        mergedTabs.append(currentTab)
      }

      self.terminalTabsByWorktreePath[normalizedPath] = mergedTabs

      if let selectedTabID = self.selectedTerminalTabIDsByWorktreePath[normalizedPath],
        !mergedTabs.contains(where: { $0.id == selectedTabID })
      {
        self.selectedTerminalTabIDsByWorktreePath[normalizedPath] = mergedTabs.first?.id
      } else if self.selectedTerminalTabIDsByWorktreePath[normalizedPath] == nil {
        self.selectedTerminalTabIDsByWorktreePath[normalizedPath] = mergedTabs.first?.id
      }

      if self.normalizedSelectedWorktreePath == normalizedPath {
        if self.selectedTerminalTabIDsByWorktreePath[normalizedPath] != nil {
          self.requestTerminalFocus(in: normalizedPath)
        } else {
          self.terminalFocusRequestIDsByWorktreePath.removeValue(forKey: normalizedPath)
        }
      }

      if restored.missingAgentCount > 0 {
        self.restoreFailureMessage = Self.formattedRestoreFailureMessage(
          missingAgentCount: restored.missingAgentCount,
          worktreeLabel: self.restoredWorktreeLabel(for: normalizedPath)
        )
      }

      self.notifyRestorableStateChanged()
    }
  }

  private func restoredWorktreeLabel(for worktreePath: String) -> String {
    worktrees.first(where: { normalizedPath($0.path) == worktreePath })?.branchName
      ?? URL(fileURLWithPath: worktreePath).lastPathComponent
  }

  private func insertTerminalTab(_ tab: WorkspaceTerminalTab, for worktreePath: String) {
    terminalTabsByWorktreePath[worktreePath, default: []].append(tab)
    selectedTerminalTabIDsByWorktreePath[worktreePath] = tab.id
    requestTerminalFocus(in: worktreePath)
    notifyRestorableStateChanged()
  }

  private func configureUITestWebsiteDemo(useLiveAgentCommands: Bool) {
    guard let worktree = selectedWorktree else { return }

    let worktreePath = normalizedPath(worktree.path)
    for tab in terminalTabsByWorktreePath[worktreePath] ?? [] {
      terminalBellTasksByTabID.removeValue(forKey: tab.id)?.cancel()
      agentActivityIdleTasksByTabID.removeValue(forKey: tab.id)?.cancel()
      GhosttyTerminalView.releaseTerminal(tab.id)
    }
    terminalTabsByWorktreePath[worktreePath] = []
    selectedTerminalTabIDsByWorktreePath.removeValue(forKey: worktreePath)

    _ = insertUITestWebsiteDemoTab(
      title: "Shell 1",
      commandDescription: "/bin/sh",
      icon: "terminal",
      worktree: worktree,
      processSpec: SandboxedProcessSpec(
        executable: "/bin/sh",
        args: [
          "-lc",
          Self.websiteDemoShellScript(
            lines: [
              "$ git status --short",
              " M README.md",
              " M Sources/WorkspaceShell.swift",
              "?? Sources/InspectorCopy.swift",
            ],
            sleepSeconds: 180
          ),
        ]
      )
    )

    _ = insertUITestWebsiteDemoTab(
      title: "Gemini",
      commandDescription: "gemini",
      icon: "gemini",
      worktree: worktree,
      processSpec: Self.websiteDemoAgentProcessSpec(
        preferredCommand: "gemini",
        fallbackLines: [
          "Gemini CLI",
          "",
          "Planning next pass...",
          "- tighten the website copy",
          "- refresh the welcome window screenshot",
          "- validate direct network status messaging",
        ],
        useLiveAgents: useLiveAgentCommands
      )
    )

    let codexTab = insertUITestWebsiteDemoTab(
      title: "Codex",
      commandDescription: "codex",
      icon: "codex",
      worktree: worktree,
      processSpec: Self.websiteDemoAgentProcessSpec(
        preferredCommand: "codex",
        fallbackLines: [
          "Codex",
          "",
          "Workspace pass ready:",
          "- Added proxied network activity in the inspector",
          "- Tightened review handoff state",
          "- Drafted summary for the current diff",
        ],
        useLiveAgents: useLiveAgentCommands
      )
    )

    reviewSummaryDraftsByWorktreePath[worktreePath] = WorkspaceReviewSummaryDraft(
      title: "Native review and network visibility",
      summary:
        "Refined the workspace shell, added observed proxied network activity in the inspector, and tightened the review handoff flow for local coding agents.",
      testing: "Seeded website demo workspace and manual UI validation.",
      risks: "Refresh screenshots when the sidebar or inspector layout changes."
    )

    if let codexTab {
      writeUITestWebsiteDemoNetworkLog(for: codexTab.id)
    }

    UITestAutomationSignal.write(
      "website-demo-ready", to: UITestAutomationConfig.current().signalFilePath)
    notifyRestorableStateChanged()
  }

  @discardableResult
  private func insertUITestWebsiteDemoTab(
    title: String,
    commandDescription: String,
    icon: String,
    worktree: DiscoveredWorktree,
    processSpec: SandboxedProcessSpec
  ) -> WorkspaceTerminalTab? {
    let worktreePath = normalizedPath(worktree.path)
    let tabID = UUID()
    let tab = WorkspaceTerminalTab(
      id: tabID,
      worktreePath: worktreePath,
      worktreeLabel: worktree.branchName ?? repoName,
      title: title,
      commandDescription: commandDescription,
      kind: .agent(profileName: title, icon: icon),
      launch: TerminalLaunchConfiguration(
        processSpec: processSpec,
        environment: TerminalLaunchConfiguration.terminalEnvironment(
          base: ProcessInfo.processInfo.environment,
          extraEnvironment: [
            "ARGON_TERMINAL_TAB_ID": tabID.uuidString
          ]
        ),
        currentDirectory: worktree.path
      ),
      isSandboxed: false,
      writableRoots: [],
      isRestorableAfterRelaunch: false
    )

    insertTerminalTab(tab, for: worktreePath)
    return tab
  }

  private func writeUITestWebsiteDemoNetworkLog(for tabID: UUID) {
    let logURL = SandboxNetworkActivityLogStore.logURL(for: tabID)
    try? FileManager.default.createDirectory(
      at: logURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = Date()
    let events = [
      (
        occurredAt: now.addingTimeInterval(-9),
        method: "GET",
        host: "api.openai.com",
        path: "/v1/responses",
        bytesUp: 28_672,
        bytesDown: 114_688
      ),
      (
        occurredAt: now.addingTimeInterval(-6),
        method: "POST",
        host: "api.anthropic.com",
        path: "/v1/messages",
        bytesUp: 12_288,
        bytesDown: 49_152
      ),
      (
        occurredAt: now.addingTimeInterval(-3),
        method: "GET",
        host: "github.com",
        path: "/fiam/argon/pull/12",
        bytesUp: 4_096,
        bytesDown: 32_768
      ),
    ]

    let body =
      events.map { event in
        """
        {"occurred_at":"\(formatter.string(from: event.occurredAt))","kind":"http","outcome":"proxied","method":"\(event.method)","host":"\(event.host)","port":443,"path":"\(event.path)","detail":null,"bytes_up":\(event.bytesUp),"bytes_down":\(event.bytesDown)}
        """
      }
      .joined(separator: "\n")

    try? body.write(to: logURL, atomically: true, encoding: .utf8)
  }

  private static func websiteDemoAgentProcessSpec(
    preferredCommand: String,
    fallbackLines: [String],
    useLiveAgents: Bool
  ) -> SandboxedProcessSpec {
    if useLiveAgents, let executable = installedExecutablePath(named: preferredCommand) {
      return SandboxedProcessSpec(executable: executable, args: [])
    }

    return SandboxedProcessSpec(
      executable: "/bin/sh",
      args: [
        "-lc",
        websiteDemoShellScript(lines: fallbackLines, sleepSeconds: 180),
      ]
    )
  }

  private static func installedExecutablePath(
    named command: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    let pathEntries = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
      .split(separator: ":")
      .map(String.init)

    for entry in pathEntries {
      let candidate = URL(fileURLWithPath: entry, isDirectory: true)
        .appendingPathComponent(command)
        .path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }

    return nil
  }

  private static func websiteDemoShellScript(lines: [String], sleepSeconds: Int) -> String {
    let quotedLines = lines.map { line in
      "'\(line.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
    return "printf '%s\\n' \(quotedLines.joined(separator: " ")); sleep \(sleepSeconds)"
  }

  private func nextOrdinal(
    in worktreePath: String,
    where predicate: (WorkspaceTerminalTab) -> Bool
  ) -> Int {
    (terminalTabsByWorktreePath[worktreePath] ?? []).filter(predicate).count + 1
  }

  private func pruneTerminalState(validPaths: Set<String>) {
    let removedTabIDs =
      terminalTabsByWorktreePath
      .filter { !validPaths.contains($0.key) }
      .values
      .flatMap { $0.map(\.id) }

    for tabID in removedTabIDs {
      terminalBellTasksByTabID.removeValue(forKey: tabID)?.cancel()
      agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()
      GhosttyTerminalView.releaseTerminal(tabID)
    }

    terminalTabsByWorktreePath =
      terminalTabsByWorktreePath
      .filter { validPaths.contains($0.key) }
    pendingRestorableTabsByWorktreePath =
      pendingRestorableTabsByWorktreePath
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

  private func pruneWorktreeState(validPaths: Set<String>) {
    worktreeSummaries =
      worktreeSummaries
      .filter { validPaths.contains($0.key) }
    reviewTargetsByWorktreePath =
      reviewTargetsByWorktreePath
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
    pruneTerminalState(validPaths: validPaths)
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

  private func scheduleWorktreeRefresh(for path: String) {
    let normalizedPath = normalizedPath(path)
    worktreeRefreshTasksByPath[normalizedPath]?.cancel()
    worktreeRefreshTasksByPath[normalizedPath] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard let self, !Task.isCancelled else { return }
      await self.refreshWorktree(path: normalizedPath)
    }
  }

  private func scheduleAllWorktreeRefreshes() {
    let paths = worktrees.map { normalizedPath($0.path) }
    for path in paths {
      refreshReviewSnapshot(for: path)
      scheduleWorktreeRefresh(for: path)
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

  private func agentTabTitle(for request: WorkspaceAgentLaunchRequest, ordinal: Int) -> String {
    guard ordinal > 1 else { return request.displayName }
    if request.useHashedDuplicateSuffix {
      return "\(request.displayName) #\(ordinal)"
    }
    return "\(request.displayName) \(ordinal)"
  }

  private func eligibleReviewAgentTabs() -> [WorkspaceTerminalTab] {
    selectedTerminalTabs.filter { tab in
      guard tab.isRunning else { return false }
      if case .agent = tab.kind {
        return true
      }
      return false
    }
  }

  private func eligibleFinalizeAgentTabs(for action: WorktreeFinalizeAction)
    -> [WorkspaceTerminalTab]
  {
    let requiredRoots = requiredWritableRoots(for: action).map(normalizedPath)

    return selectedTerminalTabs.filter { tab in
      guard tab.isRunning else { return false }
      guard case .agent = tab.kind else { return false }
      guard tab.isSandboxed else { return true }
      let allowedRoots = Set(tab.writableRoots.map(normalizedPath))
      return Set(requiredRoots).isSubset(of: allowedRoots)
    }
  }

  func finalizePrompt(for action: WorktreeFinalizeAction) throws -> String {
    try finalizeControlRequest(for: action).prompt
  }

  func prepareFinalizePrompt(
    for action: WorktreeFinalizeAction,
    sourceTabID: UUID?
  ) throws -> String {
    let request = try finalizeControlRequest(for: action)
    let pendingRequest = try beginAgentControlRequest(
      request,
      worktreePath: request.worktreePath,
      sourceTabID: sourceTabID
    )
    return try request.promptWithResponseContract(responseFilePath: pendingRequest.responseFilePath)
  }

  func cancelFinalizeRequest(for action: WorktreeFinalizeAction) {
    guard let selectedWorktree else { return }
    cancelConflictingAgentControlRequests(
      for: normalizedPath(selectedWorktree.path),
      action: .finalize(action)
    )
  }

  func pendingFinalizeRequest(
    for action: WorktreeFinalizeAction,
    worktreePath: String? = nil
  ) -> PendingWorkspaceAgentControlRequest? {
    let normalizedWorktreePath = normalizedPath(worktreePath ?? selectedWorktree?.path ?? "")
    return activeAgentControlRequestsByID.values.first { pending in
      pending.worktreePath == normalizedWorktreePath
        && pending.request.action == .finalize(action)
    }
  }

  func reviewSummaryControlRequest(
    for worktreePath: String
  ) throws -> WorkspaceAgentControlRequest {
    guard let selectedWorktree else {
      throw GitService.GitError.commandFailed("Select a worktree before preparing review.")
    }
    guard normalizedPath(selectedWorktree.path) == normalizedPath(worktreePath) else {
      throw GitService.GitError.commandFailed("Select the worktree you want to review first.")
    }
    guard let branchName = selectedWorktree.branchName, !branchName.isEmpty else {
      throw GitService.GitError.commandFailed("Review summaries require a branch-backed worktree.")
    }
    guard let target = selectedReviewTarget, target.mode == .branch else {
      throw GitService.GitError.commandFailed(
        "Review summaries require a branch-based worktree target."
      )
    }

    return WorkspaceAgentControlRequest.reviewSummary(
      repoRoot: self.target.repoRoot,
      worktreePath: selectedWorktree.path,
      branchName: branchName,
      baseRef: target.baseRef,
      compareURL: selectedPullRequestURL
    )
  }

  func finalizeControlRequest(
    for action: WorktreeFinalizeAction
  ) throws -> WorkspaceAgentControlRequest {
    guard let selectedWorktree else {
      throw GitService.GitError.commandFailed("Select a worktree before finalizing it.")
    }
    guard !selectedWorktree.isBaseWorktree else {
      throw GitService.GitError.commandFailed("The base worktree cannot be finalized this way.")
    }
    guard let branchName = selectedWorktree.branchName, !branchName.isEmpty else {
      throw GitService.GitError.commandFailed("Finalize actions require a branch-backed worktree.")
    }
    guard let target = selectedReviewTarget, target.mode == .branch else {
      throw GitService.GitError.commandFailed(
        "Finalize actions require a branch-based worktree target."
      )
    }

    return WorkspaceAgentControlRequest.finalize(
      action: action,
      repoRoot: self.target.repoRoot,
      worktreePath: selectedWorktree.path,
      branchName: branchName,
      baseRef: target.baseRef,
      compareURL: selectedPullRequestURL
    )
  }

  private func beginAgentControlRequest(
    _ request: WorkspaceAgentControlRequest,
    worktreePath: String,
    sourceTabID: UUID?
  ) throws -> PendingWorkspaceAgentControlRequest {
    let normalizedWorktreePath = normalizedPath(worktreePath)
    cancelConflictingAgentControlRequests(
      for: normalizedWorktreePath,
      action: request.action
    )

    let directoryURL = Self.agentControlDirectoryURL(for: normalizedWorktreePath)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )

    let responseFileURL =
      directoryURL
      .appendingPathComponent(request.id.uuidString.lowercased())
      .appendingPathExtension("json")
    try? FileManager.default.removeItem(at: responseFileURL)

    let pendingRequest = PendingWorkspaceAgentControlRequest(
      request: request,
      worktreePath: normalizedWorktreePath,
      responseFilePath: responseFileURL.path,
      sourceTabID: sourceTabID
    )

    activeAgentControlRequestsByID[request.id] = pendingRequest
    agentControlWatchTasksByRequestID[request.id] = Task { [weak self] in
      guard
        let response = await Self.waitForAgentControlResponse(
          at: responseFileURL,
          requestID: request.id
        ),
        !Task.isCancelled
      else {
        return
      }

      await MainActor.run {
        self?.consumeAgentControlResponse(response, responseFileURL: responseFileURL)
      }
    }

    return pendingRequest
  }

  private func cancelConflictingAgentControlRequests(
    for worktreePath: String,
    action: WorkspaceAgentControlAction
  ) {
    let conflictingRequestIDs = activeAgentControlRequestsByID.compactMap {
      (entry: Dictionary<UUID, PendingWorkspaceAgentControlRequest>.Element) -> UUID? in
      let (requestID, pending) = entry
      guard pending.worktreePath == worktreePath, pending.request.action == action else {
        return nil
      }
      return requestID
    }

    for requestID in conflictingRequestIDs {
      cancelAgentControlRequest(requestID)
    }
  }

  private func cancelAgentControlRequest(_ requestID: UUID) {
    agentControlWatchTasksByRequestID.removeValue(forKey: requestID)?.cancel()
    guard let pending = activeAgentControlRequestsByID.removeValue(forKey: requestID) else {
      return
    }
    if case .reviewSummary = pending.request.action,
      activeReviewSummaryRequestWorktreePath == pending.worktreePath
    {
      activeReviewSummaryRequestWorktreePath = nil
    }
  }

  private func consumeAgentControlResponse(
    _ response: WorkspaceAgentControlResponse,
    responseFileURL: URL
  ) {
    defer { try? FileManager.default.removeItem(at: responseFileURL) }

    guard let pending = activeAgentControlRequestsByID[response.requestID] else { return }
    cancelAgentControlRequest(response.requestID)

    switch (pending.request.action, response) {
    case (
      .reviewSummary,
      .reviewSummary(_, let status, let message, let draft)
    ):
      handleReviewSummaryResponse(
        status: status,
        message: message,
        draft: draft,
        pendingRequest: pending
      )
    case (
      .finalize(let expectedAction),
      .finalize(_, let action, let status, let message, _, let pullRequestURL, let followUp)
    ):
      guard action == expectedAction else {
        errorMessage = "Agent returned a finalize response for the wrong action."
        return
      }
      handleFinalizeResponse(
        status: status,
        message: message,
        pullRequestURL: pullRequestURL,
        followUp: followUp,
        pendingRequest: pending
      )
    default:
      errorMessage = "Agent returned a response for the wrong request kind."
    }
  }

  private func handleReviewSummaryResponse(
    status: WorkspaceAgentControlStatus,
    message: String,
    draft: WorkspaceReviewSummaryDraft?,
    pendingRequest: PendingWorkspaceAgentControlRequest
  ) {
    activeReviewSummaryRequestWorktreePath = nil

    switch status {
    case .success:
      guard let draft else {
        errorMessage = "Agent returned a successful review summary response without a draft."
        return
      }
      let normalizedDraft = draft.normalized()
      persistReviewSummaryDraft(normalizedDraft, for: pendingRequest.worktreePath)
      if var preparation = pendingReviewPreparation,
        normalizedPath(preparation.worktreePath) == pendingRequest.worktreePath
      {
        preparation.draft = normalizedDraft
        pendingReviewPreparation = preparation
      }
      if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        launchWarningMessage = message
      }
    case .failed:
      errorMessage = message
    }
  }

  private func handleFinalizeResponse(
    status: WorkspaceAgentControlStatus,
    message: String,
    pullRequestURL: String?,
    followUp: String?,
    pendingRequest: PendingWorkspaceAgentControlRequest
  ) {
    switch status {
    case .success:
      let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedFollowUp = followUp?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let pullRequestURL, !pullRequestURL.isEmpty,
        normalizedSelectedWorktreePath == pendingRequest.worktreePath
      {
        selectedPullRequestURL = pullRequestURL
      }
      let statusParts = [trimmedMessage] + (trimmedFollowUp.map { [$0] } ?? [])
      let displayMessage = statusParts.filter { !$0.isEmpty }.joined(separator: " ")
      if !displayMessage.isEmpty {
        launchWarningMessage = displayMessage
      }
      Task { @MainActor [weak self] in
        self?.scheduleAllWorktreeRefreshes()
      }
    case .failed:
      errorMessage = message
    }
  }

  nonisolated private static func waitForAgentControlResponse(
    at responseFileURL: URL,
    requestID: UUID
  ) async -> WorkspaceAgentControlResponse? {
    let decoder = JSONDecoder()

    while !Task.isCancelled {
      if let data = try? Data(contentsOf: responseFileURL),
        let response = try? decoder.decode(WorkspaceAgentControlResponse.self, from: data),
        response.requestID == requestID
      {
        return response
      }

      try? await Task.sleep(for: .milliseconds(250))
    }

    return nil
  }

  nonisolated private static func agentControlDirectoryURL(for worktreePath: String) -> URL {
    URL(fileURLWithPath: worktreePath)
      .appendingPathComponent(".tmp", isDirectory: true)
      .appendingPathComponent("argon-agent-control", isDirectory: true)
  }

  private func mergeBackOptions(for topology: BranchTopology) -> [WorktreeFinalizeAction] {
    let preferredStrategy = WorktreeMergeStrategySettings.strategy(for: target.repoRoot)

    var options: [WorktreeFinalizeAction]
    if topology.needsRebase {
      options = [
        .mergeCommitToBase,
        .rebaseAndMergeToBase,
        .squashAndMergeToBase,
      ]
    } else if topology.canFastForwardBase {
      options = [
        .fastForwardToBase,
        .mergeCommitToBase,
      ]
    } else {
      options = [.mergeCommitToBase]
    }

    if let preferredIndex = options.firstIndex(of: preferredStrategy.finalizeAction) {
      let preferredAction = options.remove(at: preferredIndex)
      options.insert(preferredAction, at: 0)
    }

    return options
  }

  private func persistReviewSummaryDraft(
    _ draft: WorkspaceReviewSummaryDraft,
    for worktreePath: String
  ) {
    let normalizedPath = normalizedPath(worktreePath)
    let normalizedDraft = draft.normalized()
    if normalizedDraft.isEmpty {
      reviewSummaryDraftsByWorktreePath.removeValue(forKey: normalizedPath)
    } else {
      reviewSummaryDraftsByWorktreePath[normalizedPath] = normalizedDraft
    }
    notifyRestorableStateChanged()
  }

  private func requiredWritableRoots(for action: WorktreeFinalizeAction) -> [String] {
    guard let selectedWorktree else { return [target.repoRoot] }
    if action.requiresBaseRepoWriteAccess {
      return [selectedWorktree.path, target.repoRoot]
    }
    return [selectedWorktree.path]
  }

  private func uniqueWritableRoots(
    primaryRoot: String,
    additionalRoots: [String]
  ) -> [String] {
    var roots: [String] = []
    var seen = Set<String>()

    for root in [primaryRoot] + additionalRoots {
      let normalized = normalizedPath(root)
      if seen.insert(normalized).inserted {
        roots.append(normalized)
      }
    }

    return roots
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

  private func notifyRestorableStateChanged() {
    onRestorableStateChange?()
  }

  private func resolvedInventorySelectionPath(
    preferredSelection: String,
    validPaths: Set<String>
  ) -> String? {
    if validPaths.contains(preferredSelection) {
      return preferredSelection
    }

    let normalizedRepoRoot = normalizedPath(target.repoRoot)
    if validPaths.contains(normalizedRepoRoot) {
      return normalizedRepoRoot
    }

    return worktrees.first.map { normalizedPath($0.path) }
  }

  private func clearSelectedWorktreeDetails() {
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

  func stageReviewLaunch(target: ReviewTarget, agentTabID: UUID) {
    stagedReviewLaunch = StagedReviewLaunch(target: target, agentTabID: agentTabID)
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

private struct LoadedWorkspace: Sendable {
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

private struct SelectionDetails: Sendable {
  let summary: WorktreeDiffSummary
  let files: [FileDiff]
  let diffStat: String
  let pullRequestURL: String?
  let reviewTarget: ResolvedTarget?
  let branchTopology: BranchTopology?
}

private struct RestoredPersistedTabs: Sendable {
  let persistedTabs: [PersistedWorkspaceTerminalTab]
  let missingAgentCount: Int
}

private struct StagedReviewLaunch {
  let target: ReviewTarget
  let agentTabID: UUID
}

enum AgentSessionProvider: String, Sendable {
  case codex
}

struct AgentSessionRecord: Sendable, Equatable {
  let provider: AgentSessionProvider
  let sessionID: String
  let cwd: String
  let startedAt: Date
}

private struct CodexSessionRecord: Sendable, Equatable {
  let sessionID: String
  let cwd: String
  let startedAt: Date
}

struct WorktreeRemovalRequest: Identifiable, Sendable {
  var id: String { worktreePath }

  let worktreePath: String
  let displayName: String
  let branchName: String?
  let hasUncommittedChanges: Bool
  let canDeleteBranch: Bool
  let branchComparisonBaseRef: String?
  let branchHasUniqueCommits: Bool

  var shouldSkipConfirmation: Bool {
    !hasUncommittedChanges && (!canDeleteBranch || !branchHasUniqueCommits)
  }

  var defaultDeletesBranch: Bool {
    canDeleteBranch
  }
}

private struct WorktreeRemovalBranchDetails: Sendable {
  let hasUncommittedChanges: Bool
  let branchName: String?
  let canDeleteBranch: Bool
  let branchComparisonBaseRef: String?
  let branchHasUniqueCommits: Bool
}
