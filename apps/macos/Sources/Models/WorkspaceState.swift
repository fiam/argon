import Foundation

@MainActor
@Observable
final class WorkspaceState {
  nonisolated(unsafe) static var tabRestoreTestDelay: Duration?
  nonisolated(unsafe) static var terminalBellFlashDuration: Duration = .seconds(1)
  nonisolated(unsafe) static var terminalAttentionVisibleClearDelay: Duration = .seconds(1)
  nonisolated(unsafe) static var agentThinkingIdleTimeout: Duration = .seconds(3)
  nonisolated(unsafe) static var commandStatusProvider: (@Sendable ([String]) -> [String: Bool])?
  nonisolated(unsafe) static var terminalSessionReferenceProvider:
    (@Sendable (UUID, String) -> TerminalSessionReference?) = { tabID, workspacePath in
      TerminalSessionBackends.reference(for: tabID, workspacePath: workspacePath)
    }
  nonisolated(unsafe) static var terminalSessionLaunchBuilder:
    (
      @Sendable (TerminalSessionReference, TerminalLaunchConfiguration) ->
        TerminalLaunchConfiguration
    ) = { session, launch in
      TerminalSessionBackends.attachLaunchConfiguration(reference: session, createLaunch: launch)
    }
  nonisolated(unsafe) static var terminalSessionStopper:
    (@Sendable (TerminalSessionReference) -> Void) = { session in
      TerminalSessionBackends.stop(reference: session)
    }
  nonisolated(unsafe) static var terminalSessionRunningChecker:
    (@Sendable (TerminalSessionReference) -> Bool) = { session in
      TerminalSessionBackends.isRunning(reference: session)
    }
  nonisolated(unsafe) static var terminalSessionReconnectChecker:
    (@Sendable (TerminalSessionReference) -> Bool) = { session in
      TerminalSessionBackends.canReconnect(reference: session)
    }
  private static let restoredAgentAttentionSuppressionInterval: TimeInterval = 3
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
  nonisolated(unsafe) static var fastForwardMergeBackPerformer:
    (@Sendable (FastForwardMergeBackRequest) throws -> FastForwardMergeBackResult) = {
      request in
      try GitService.fastForwardMergeBack(request)
    }

  var worktrees: [DiscoveredWorktree] = []
  var worktreeSummaries: [String: WorktreeDiffSummary] = [:]
  var reviewTargetsByWorktreePath: [String: ResolvedTarget?] = [:]
  var diffModesByWorktreePath: [String: WorkspaceDiffMode] = [:]
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
  var worktreeRemovalErrorDialog: WorkspaceErrorDialog?
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
  var completedMergeBackWorktreePaths: Set<String> = []
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
  private var terminalAttentionVisibleClearTasksByTabID: [UUID: Task<Void, Never>] = [:]
  private var agentActivityIdleTasksByTabID: [UUID: Task<Void, Never>] = [:]
  private var activeAgentControlRequestsByID: [UUID: PendingWorkspaceAgentControlRequest] = [:]
  private var agentControlWatchTasksByRequestID: [UUID: Task<Void, Never>] = [:]
  private var activeLocalMergeBackWorktreePaths: Set<String> = []
  private var pendingRestorableTabsByWorktreePath: [String: [PersistedWorkspaceTerminalTab]] = [:]
  private var pendingTabRestoreTasksByWorktreePath: [String: Task<Void, Never>] = [:]
  private var pendingAgentActivitySummariesByWorktreePath: [String: WorktreeAgentActivitySummary] =
    [:]
  private var selectionLoadRequestID: UUID?
  private var shouldLaunchReviewAfterNextAgentTab = false
  private var pendingReviewPreparationAfterAgentLaunch: WorkspaceReviewPreparation?
  private var stagedReviewLaunch: StagedReviewLaunch?
  private var preparedReviewTargetsByAgentTabID: [UUID: ReviewTarget] = [:]
  private var didApplyUITestWebsiteDemo = false
  private var isPreparingForTerminalDetach = false
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

  var runningPersistentAgentCount: Int {
    allTerminalTabs.filter { tab in
      tab.shouldKeepRunningAcrossQuit
    }.count
  }

  var hasPendingRestorableTerminalTabs: Bool {
    pendingRestorableTabsByWorktreePath.values.contains { !$0.isEmpty }
  }

  var quitAgentSummary: WorkspaceQuitAgentSummary {
    allTerminalTabs.reduce(.empty) { summary, tab in
      guard tab.shouldWarnBeforeQuit else { return summary }

      return WorkspaceQuitAgentSummary(
        warningCount: summary.warningCount + 1,
        keepRunningCount: summary.keepRunningCount
          + (tab.shouldKeepTerminalSessionAliveAcrossQuit ? 1 : 0),
        thinkingCount: summary.thinkingCount + 1
      )
    }
  }

  var isPreparingReviewAgentLaunch: Bool {
    shouldLaunchReviewAfterNextAgentTab
  }

  var canFinalizeSelectedWorktree: Bool {
    guard let selectedWorktree, !selectedWorktree.isBaseWorktree else { return false }
    return selectedReviewTarget?.mode == .branch
  }

  var selectedDiffMode: WorkspaceDiffMode {
    guard let selectedWorktree else { return .uncommitted }
    let mode = effectiveDiffMode(for: selectedWorktree)
    if mode == .allChanges, selectedReviewTarget?.mode == .uncommitted {
      return .uncommitted
    }
    return mode
  }

  var selectedWorktreeSupportsAllChanges: Bool {
    guard let selectedWorktree else { return false }
    return Self.supportsAllChangesDiff(for: selectedWorktree)
  }

  var canRebaseSelectedWorktree: Bool {
    canFinalizeSelectedWorktree && (selectedBranchTopology?.needsRebase ?? false)
  }

  var canMergeBackSelectedWorktree: Bool {
    canFinalizeSelectedWorktree && selectedBranchTopology != nil
  }

  var canOpenPullRequestForSelectedWorktree: Bool {
    canFinalizeSelectedWorktree && ((selectedBranchTopology?.aheadCount ?? 0) > 0)
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

  private func requestedDiffMode(for path: String) -> WorkspaceDiffMode {
    diffModesByWorktreePath[normalizedPath(path)] ?? .allChanges
  }

  private func effectiveDiffMode(for worktree: DiscoveredWorktree) -> WorkspaceDiffMode {
    Self.effectiveDiffMode(for: worktree, requested: requestedDiffMode(for: worktree.path))
  }

  private func effectiveDiffMode(for path: String) -> WorkspaceDiffMode {
    guard let worktree = worktrees.first(where: { normalizedPath($0.path) == normalizedPath(path) })
    else {
      return requestedDiffMode(for: path)
    }
    return effectiveDiffMode(for: worktree)
  }

  nonisolated private static func supportsAllChangesDiff(for worktree: DiscoveredWorktree) -> Bool {
    guard !worktree.isBaseWorktree, !worktree.isDetached else { return false }
    return !(worktree.branchName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  nonisolated private static func effectiveDiffMode(
    for worktree: DiscoveredWorktree,
    requested: WorkspaceDiffMode
  ) -> WorkspaceDiffMode {
    supportsAllChangesDiff(for: worktree) ? requested : .uncommitted
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
      && diffModesByWorktreePath.isEmpty
      && reviewSnapshotsByWorktreePath.isEmpty
      && reviewSummaryDraftsByWorktreePath.isEmpty
      && conflictStatesByWorktreePath.isEmpty
      && terminalTabsByWorktreePath.isEmpty
      && pendingRestorableTabsByWorktreePath.isEmpty
      && pendingTabRestoreTasksByWorktreePath.isEmpty
      && pendingAgentActivitySummariesByWorktreePath.isEmpty
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
    let restoreMetadataByProfileIDOrName = Self.restoreMetadataByProfileIDOrName(
      savedProfiles: SavedAgentProfiles().profiles
    )

    selectedWorktreePath = normalizedPath(snapshot.target.selectedWorktreePath ?? target.repoRoot)
    terminalTabsByWorktreePath = [:]
    pendingAgentActivitySummariesByWorktreePath = [:]
    pendingRestorableTabsByWorktreePath = snapshot.terminalTabsByWorktreePath.reduce(
      into: [String: [PersistedWorkspaceTerminalTab]]()
    ) { partialResult, entry in
      partialResult[normalizedPath(entry.key)] = entry.value.map { tab in
        Self.persistedTabByResolvingResumeTemplate(
          from: PersistedWorkspaceTerminalTab(
            id: tab.id,
            profileID: tab.profileID,
            worktreePath: normalizedPath(tab.worktreePath),
            worktreeLabel: tab.worktreeLabel,
            title: tab.title,
            commandDescription: tab.commandDescription,
            baseCommandDescription: tab.baseCommandDescription,
            kind: tab.kind,
            agentFamilyID: tab.agentFamilyID,
            createdAt: tab.createdAt,
            isSandboxed: tab.isSandboxed,
            yoloMode: tab.yoloMode,
            writableRoots: tab.writableRoots.map(normalizedPath),
            resumeArgumentTemplate: tab.resumeArgumentTemplate,
            keepsRunningAfterQuit: tab.keepsRunningAfterQuit,
            terminalSession: tab.terminalSession,
            resumeSessionID: tab.resumeSessionID,
            resumeCommandDescription: tab.resumeCommandDescription,
            hasAttention: tab.hasAttention,
            agentActivityState: tab.agentActivityState
          ),
          using: restoreMetadataByProfileIDOrName
        )
      }
    }
    refreshPendingAgentActivitySummaries()

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

    let validPaths = Set(worktrees.map { normalizedPath($0.path) })
    if !validPaths.isEmpty {
      if let selectedWorktreePath = normalizedSelectedWorktreePath,
        validPaths.contains(selectedWorktreePath)
      {
        materializePendingRunningAgentTabs(for: selectedWorktreePath)
      }
      startRunningBackgroundAgentRestores(
        validPaths: validPaths,
        excluding: normalizedSelectedWorktreePath
      )
    }
    refreshPendingAgentActivitySummaries()
  }

  func mergePersistedRunningAgentTabs(from snapshot: PersistedWorkspaceWindowSnapshot) {
    let restoreMetadataByProfileIDOrName = Self.restoreMetadataByProfileIDOrName(
      savedProfiles: SavedAgentProfiles().profiles
    )
    let validPaths = Set(worktrees.map { normalizedPath($0.path) })
    let materializedTabIDs = Set(terminalTabsByWorktreePath.values.flatMap { $0.map(\.id) })
    var changedPaths = Set<String>()

    for entry in snapshot.terminalTabsByWorktreePath {
      let worktreePath = normalizedPath(entry.key)
      if !validPaths.isEmpty, !validPaths.contains(worktreePath) {
        continue
      }

      let pendingTabIDs = Set((pendingRestorableTabsByWorktreePath[worktreePath] ?? []).map(\.id))
      let runningAgentTabs = entry.value.compactMap { tab -> PersistedWorkspaceTerminalTab? in
        let normalizedTab = Self.persistedTabByResolvingResumeTemplate(
          from: PersistedWorkspaceTerminalTab(
            id: tab.id,
            profileID: tab.profileID,
            worktreePath: normalizedPath(tab.worktreePath),
            worktreeLabel: tab.worktreeLabel,
            title: tab.title,
            commandDescription: tab.commandDescription,
            baseCommandDescription: tab.baseCommandDescription,
            kind: tab.kind,
            agentFamilyID: tab.agentFamilyID,
            createdAt: tab.createdAt,
            isSandboxed: tab.isSandboxed,
            yoloMode: tab.yoloMode,
            writableRoots: tab.writableRoots.map(normalizedPath),
            resumeArgumentTemplate: tab.resumeArgumentTemplate,
            keepsRunningAfterQuit: tab.keepsRunningAfterQuit,
            terminalSession: tab.terminalSession,
            resumeSessionID: tab.resumeSessionID,
            resumeCommandDescription: tab.resumeCommandDescription,
            hasAttention: tab.hasAttention,
            agentActivityState: tab.agentActivityState
          ),
          using: restoreMetadataByProfileIDOrName
        )
        guard !materializedTabIDs.contains(normalizedTab.id),
          !pendingTabIDs.contains(normalizedTab.id),
          Self.pendingTabRepresentsRunningBackgroundAgent(normalizedTab)
        else {
          return nil
        }
        return normalizedTab
      }

      guard !runningAgentTabs.isEmpty else { continue }
      pendingRestorableTabsByWorktreePath[worktreePath, default: []].append(
        contentsOf: runningAgentTabs
      )
      changedPaths.insert(worktreePath)
    }

    guard !changedPaths.isEmpty else { return }

    for changedPath in changedPaths {
      refreshPendingAgentActivitySummary(for: changedPath)
    }
    if let selectedWorktreePath = normalizedSelectedWorktreePath,
      changedPaths.contains(selectedWorktreePath)
    {
      materializePendingRunningAgentTabs(for: selectedWorktreePath)
    }
    if !validPaths.isEmpty {
      startRunningBackgroundAgentRestores(
        validPaths: validPaths,
        excluding: normalizedSelectedWorktreePath
      )
    }
    notifyRestorableStateChanged()
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
    materializePendingRunningAgentTabs(for: worktreePath)
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

    if selectedBranchTopology.aheadCount <= 1 {
      let action: WorktreeFinalizeAction =
        selectedBranchTopology.needsRebase ? .rebaseAndMergeToBase : .fastForwardToBase
      beginFinalizeFlow(action)
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
    guard let selectedWorktree else { return }

    dismissMergeBackOptions()
    if action.isMergeBackAction {
      completedMergeBackWorktreePaths.remove(normalizedPath(selectedWorktree.path))
    }

    if beginLocalMergeBackIfAvailable(for: action, selectedWorktree: selectedWorktree) {
      return
    }

    beginAgentFinalizeFlow(action)
  }

  private func beginAgentFinalizeFlow(_ action: WorktreeFinalizeAction) {
    activeFinalizeAction = action
    if let selectedWorktreePath = normalizedSelectedWorktreePath {
      materializePendingRunningAgentTabs(for: selectedWorktreePath)
    }
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

  @discardableResult
  private func beginLocalMergeBackIfAvailable(
    for action: WorktreeFinalizeAction,
    selectedWorktree: DiscoveredWorktree
  ) -> Bool {
    guard action == .fastForwardToBase,
      selectedBranchTopology?.canFastForwardBase == true,
      let target = selectedReviewTarget,
      target.mode == .branch,
      let branchName = selectedWorktree.branchName,
      !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return false
    }

    let normalizedWorktreePath = normalizedPath(selectedWorktree.path)
    guard !activeLocalMergeBackWorktreePaths.contains(normalizedWorktreePath) else {
      return true
    }

    activeLocalMergeBackWorktreePaths.insert(normalizedWorktreePath)
    let request = FastForwardMergeBackRequest(
      repoRoot: self.target.repoRoot,
      worktreePath: selectedWorktree.path,
      branchName: branchName,
      baseRef: target.baseRef,
      headRef: target.headRef
    )

    Task { [weak self] in
      let result = await Task.detached {
        Result {
          try Self.fastForwardMergeBackPerformer(request)
        }
      }.value

      await MainActor.run {
        guard let self else { return }
        self.activeLocalMergeBackWorktreePaths.remove(normalizedWorktreePath)

        switch result {
        case .success(let mergeBackResult):
          self.completedMergeBackWorktreePaths.insert(normalizedWorktreePath)
          self.errorMessage = nil
          self.launchWarningMessage = mergeBackResult.message
          self.scheduleAllWorktreeRefreshes()
        case .failure:
          guard self.normalizedSelectedWorktreePath == normalizedWorktreePath else { return }
          self.beginAgentFinalizeFlow(action)
        }
      }
    }

    return true
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
        let prompt = try prepareFinalizePrompt(
          for: finalizeAction,
          sourceTabID: nil,
          sourceSandboxed: options.sandboxEnabled
        )
        let openedTab = openAgentTab(
          options.buildRequest(
            prompt: prompt
          ))
        guard openedTab != nil else {
          cancelFinalizeRequest(for: finalizeAction)
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
    let terminalSession =
      request.keepRunningWhileThinking
      ? Self.terminalSessionReferenceProvider(tabID, worktree.path)
      : nil
    TerminalSessionLifecycleLog.record(
      "open-agent-tab tab=\(tabID.uuidString.lowercased()) session=\(terminalSession?.sessionID ?? "none") profile=\(request.displayName) family=\(request.agentFamilyID?.rawValue ?? "none") sandbox=\(request.sandboxEnabled) yolo=\(request.yoloMode) resume=\(request.resumeSessionID ?? "none")"
    )
    let sandboxAgentFamily =
      request.agentFamilyID.map(AgentHarnesses.sandboxAgentFamily)
      ?? sandboxAgentFamily(from: request.command)
    let launchCommand = request.launchCommandOverride ?? request.command
    let directLaunch =
      request.sandboxEnabled
      ? TerminalLaunchConfiguration.sandboxedCommand(
        launchCommand,
        currentDirectory: worktree.path,
        writableRoots: writableRoots,
        launchKind: "agent",
        agentFamily: sandboxAgentFamily,
        tabID: tabID
      )
      : TerminalLaunchConfiguration.command(
        launchCommand,
        currentDirectory: worktree.path,
        tabID: tabID
      )
    let launch =
      terminalSession.map { session in
        Self.terminalSessionLaunchBuilder(session, directLaunch)
      } ?? directLaunch
    let resumeArgumentTemplate =
      request.isRestorableAfterRelaunch
      ? request.resumeArgumentTemplate
      : ""
    let resumeCommandDescription = renderAgentResumeCommand(
      baseCommand: request.command,
      resumeArgumentTemplate: resumeArgumentTemplate,
      sessionID: request.resumeSessionID
    )

    let tab = WorkspaceTerminalTab(
      id: tabID,
      profileID: request.profileID,
      worktreePath: worktreePath,
      worktreeLabel: worktree.branchName ?? repoName,
      title: agentTabTitle(for: request, ordinal: ordinal),
      commandDescription: request.command,
      baseCommandDescription: request.baseCommandDescription,
      kind: .agent(profileName: request.displayName, icon: request.icon),
      agentFamilyID: request.agentFamilyID,
      launch: launch,
      isSandboxed: request.sandboxEnabled,
      yoloMode: request.yoloMode,
      yoloFlag: request.yoloFlag,
      writableRoots: writableRoots.map(normalizedPath),
      isRestorableAfterRelaunch: request.isRestorableAfterRelaunch,
      resumeArgumentTemplate: resumeArgumentTemplate,
      keepsRunningAfterQuit: request.keepRunningWhileThinking,
      terminalSession: terminalSession,
      resumeSessionID: request.resumeSessionID,
      resumeCommandDescription: request.launchCommandOverride ?? resumeCommandDescription
    )

    if let sessionID = request.resumeSessionID {
      recordAgentSessionRestoreMetadata(for: tab, sessionID: sessionID)
    }
    insertTerminalTab(tab, for: worktreePath)
    return tab
  }

  func restorableAgentSessions(
    savedProfiles: [SavedAgentProfile],
    notBefore: Date = .distantPast
  ) -> [WorkspaceRestorableAgentSession] {
    guard let worktreePath = normalizedSelectedWorktreePath else { return [] }

    let profilesByID = Self.agentProfilesByID(savedProfiles: savedProfiles)
    let runningSessionKeys = Set(
      selectedTerminalTabs.compactMap { tab -> String? in
        guard tab.isRunning else { return nil }
        guard let sessionID = tab.resumeSessionID, !sessionID.isEmpty else { return nil }
        let familyID =
          tab.agentFamilyID ?? AgentHarnesses.familyID(matchingCommand: tab.commandDescription)
        guard let familyID else { return nil }
        return Self.agentSessionKey(familyID: familyID, sessionID: sessionID)
      }
    )
    let stoppedTabIDsBySessionKey = selectedTerminalTabs.reduce(into: [String: UUID]()) {
      partialResult,
      tab in
      guard !tab.isRunning else { return }
      guard let sessionID = tab.resumeSessionID, !sessionID.isEmpty else { return }
      let familyID =
        tab.agentFamilyID ?? AgentHarnesses.familyID(matchingCommand: tab.commandDescription)
      guard let familyID else { return }
      let sessionKey = Self.agentSessionKey(familyID: familyID, sessionID: sessionID)
      partialResult[sessionKey] = tab.id
    }

    var sessionsByKey: [String: WorkspaceRestorableAgentSession] = [:]
    for familyID in AgentFamilyID.allCases {
      let defaultProfile = profilesByID[familyID.defaultProfileID] ?? familyID.defaultProfile

      for record in AgentHarnesses.resumeSessionRecords(for: familyID, notBefore: notBefore) {
        guard normalizedPath(record.cwd) == worktreePath else { continue }
        let sessionKey = Self.agentSessionKey(familyID: familyID, sessionID: record.sessionID)
        guard !runningSessionKeys.contains(sessionKey) else { continue }

        let metadata = AgentSessionRestoreMetadataStore.metadata(
          familyID: familyID,
          sessionID: record.sessionID,
          cwd: record.cwd
        )
        let sessionProfile =
          metadata?.profileID.flatMap { profileID in
            profilesByID[profileID]
          }
          ?? defaultProfile
        let resumeArgumentTemplate = Self.sessionSpecificResumeArgumentTemplate(
          for: familyID,
          profile: sessionProfile
        )
        guard !resumeArgumentTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { continue }

        let session = WorkspaceRestorableAgentSession(
          familyID: familyID,
          profileID: sessionProfile.id,
          profileName: sessionProfile.name,
          command: sessionProfile.fullCommand(yolo: false),
          icon: sessionProfile.icon,
          resumeArgumentTemplate: resumeArgumentTemplate,
          sessionID: record.sessionID,
          cwd: normalizedPath(record.cwd),
          yoloMode: metadata?.yoloMode ?? false,
          sandboxEnabled: metadata?.sandboxEnabled ?? true,
          startedAt: record.startedAt,
          openStoppedTabID: stoppedTabIDsBySessionKey[sessionKey]
        )
        if let existing = sessionsByKey[sessionKey], existing.startedAt >= session.startedAt {
          continue
        }
        sessionsByKey[sessionKey] = session
      }
    }

    return sessionsByKey.values.sorted {
      if $0.startedAt == $1.startedAt {
        return $0.id < $1.id
      }
      return $0.startedAt > $1.startedAt
    }
  }

  @discardableResult
  func restoreAgentSession(
    _ session: WorkspaceRestorableAgentSession
  ) -> WorkspaceTerminalTab? {
    TerminalSessionLifecycleLog.record(
      "restore-agent-session family=\(session.familyID.rawValue) codex-session=\(session.sessionID) cwd=\(session.cwd) sandbox=\(session.sandboxEnabled) stopped-tab=\(session.openStoppedTabID?.uuidString.lowercased() ?? "none")"
    )
    let command = Self.agentCommand(
      baseCommand: session.command,
      yoloMode: session.yoloMode,
      yoloFlag: session.yoloFlag
    )
    guard
      let resumeCommand = renderAgentResumeCommand(
        baseCommand: command,
        resumeArgumentTemplate: session.resumeArgumentTemplate,
        sessionID: session.sessionID
      )
    else {
      errorMessage = "\(session.profileName) cannot restore this session."
      return nil
    }

    closeStoppedAgentTabs(matching: session)

    return openAgentTab(
      WorkspaceAgentLaunchRequest(
        profileID: session.profileID,
        displayName: session.profileName,
        command: command,
        baseCommandDescription: session.command,
        launchCommandOverride: resumeCommand,
        icon: session.icon,
        agentFamilyID: session.familyID,
        sandboxEnabled: session.sandboxEnabled,
        yoloMode: session.yoloMode,
        yoloFlag: session.yoloFlag,
        resumeArgumentTemplate: session.resumeArgumentTemplate,
        resumeSessionID: session.sessionID,
        keepRunningWhileThinking:
          AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence
      )
    )
  }

  private func closeStoppedAgentTabs(matching session: WorkspaceRestorableAgentSession) {
    let matchingTabIDs = allTerminalTabs.compactMap { tab -> UUID? in
      guard !tab.isRunning else { return nil }
      guard normalizedPath(tab.worktreePath) == normalizedPath(session.cwd) else { return nil }
      guard tab.resumeSessionID == session.sessionID else { return nil }
      let familyID =
        tab.agentFamilyID ?? AgentHarnesses.familyID(matchingCommand: tab.baseCommandDescription)
      guard familyID == session.familyID else { return nil }
      return tab.id
    }

    for tabID in matchingTabIDs {
      TerminalSessionLifecycleLog.record(
        "close-stopped-matching-tab tab=\(tabID.uuidString.lowercased()) codex-session=\(session.sessionID)"
      )
      closeTerminalTab(tabID)
    }
  }

  @discardableResult
  func relaunchAgentTab(
    _ tabID: UUID,
    sandboxEnabled: Bool? = nil,
    yoloMode: Bool? = nil,
    profile: SavedAgentProfile? = nil
  ) -> WorkspaceTerminalTab? {
    guard let tab = terminalTab(for: tabID) else { return nil }
    guard case .agent(let profileName, let icon) = tab.kind else { return nil }

    let nextSandboxEnabled = sandboxEnabled ?? tab.isSandboxed
    let nextYoloMode = yoloMode ?? tab.yoloMode
    let nextProfileID = profile?.id ?? tab.profileID
    let nextProfileName = profile?.name ?? profileName
    let nextIcon = profile?.icon ?? icon
    let nextYoloFlag = profile?.yoloFlag ?? tab.yoloFlag
    let nextResumeArgumentTemplate = profile?.resumeArgumentTemplate ?? tab.resumeArgumentTemplate
    let nextBaseCommandDescription =
      profile?.fullCommand(yolo: false, sandboxed: nextSandboxEnabled) ?? tab.baseCommandDescription
    let nextFamilyID =
      profile?.familyID
      ?? tab.agentFamilyID
      ?? AgentHarnesses.familyID(
        matchingCommand: nextBaseCommandDescription
      )
    guard
      nextSandboxEnabled != tab.isSandboxed || nextYoloMode != tab.yoloMode
        || nextProfileID != tab.profileID
        || nextBaseCommandDescription != tab.baseCommandDescription
        || nextResumeArgumentTemplate != tab.resumeArgumentTemplate
    else {
      return tab
    }

    let sessionID = tab.resumeSessionID ?? hydrateAgentResumeSessionID(for: tab)
    if let sessionID {
      tab.resumeSessionID = sessionID
      recordAgentSessionRestoreMetadata(
        for: tab,
        sessionID: sessionID,
        profileID: nextProfileID,
        yoloMode: nextYoloMode,
        sandboxEnabled: nextSandboxEnabled
      )
    }

    let command = Self.agentCommand(
      baseCommand: nextBaseCommandDescription,
      yoloMode: nextYoloMode,
      yoloFlag: nextYoloFlag
    )
    let launchCommandOverride = renderAgentResumeCommand(
      baseCommand: command,
      resumeArgumentTemplate: nextResumeArgumentTemplate,
      sessionID: sessionID
    )
    let additionalWritableRoots = tab.writableRoots.filter { $0 != tab.worktreePath }
    let request = WorkspaceAgentLaunchRequest(
      profileID: nextProfileID,
      displayName: nextProfileName,
      command: command,
      baseCommandDescription: nextBaseCommandDescription,
      launchCommandOverride: launchCommandOverride,
      icon: nextIcon,
      agentFamilyID: nextFamilyID,
      sandboxEnabled: nextSandboxEnabled,
      yoloMode: nextYoloMode,
      yoloFlag: nextYoloFlag,
      resumeArgumentTemplate: nextResumeArgumentTemplate,
      resumeSessionID: sessionID,
      keepRunningWhileThinking:
        AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence,
      useHashedDuplicateSuffix: false,
      isRestorableAfterRelaunch: tab.isRestorableAfterRelaunch,
      additionalWritableRoots: additionalWritableRoots
    )

    if normalizedSelectedWorktreePath != tab.worktreePath {
      selectWorktree(path: tab.worktreePath)
    }
    closeTerminalTab(tabID)
    return openAgentTab(request)
  }

  func selectTerminalTab(_ tabID: UUID) {
    guard let worktreePath = normalizedSelectedWorktreePath else { return }
    guard terminalTabsByWorktreePath[worktreePath]?.contains(where: { $0.id == tabID }) == true
    else { return }
    selectedTerminalTabIDsByWorktreePath[worktreePath] = tabID
    clearTerminalAttentionState(tabID)
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
    clearTerminalAttentionState(tabID)
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

  func beginTerminalAttentionVisibilityDwell(for tabID: UUID) {
    guard let tab = terminalTab(for: tabID), tab.hasAttention else { return }

    terminalAttentionVisibleClearTasksByTabID.removeValue(forKey: tabID)?.cancel()

    let worktreePath = tab.worktreePath
    let delay = Self.terminalAttentionVisibleClearDelay
    terminalAttentionVisibleClearTasksByTabID[tabID] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }

      guard let self else { return }
      self.terminalAttentionVisibleClearTasksByTabID.removeValue(forKey: tabID)
      guard self.normalizedSelectedWorktreePath == worktreePath,
        self.selectedTerminalTab?.id == tabID
      else {
        return
      }
      guard self.clearTerminalAttentionState(tabID) else { return }
      self.notifyRestorableStateChanged()
    }
  }

  func cancelTerminalAttentionVisibilityDwell(for tabID: UUID) {
    terminalAttentionVisibleClearTasksByTabID.removeValue(forKey: tabID)?.cancel()
  }

  func recordTerminalTitleChange(_ title: String, for tabID: UUID) {
    guard let tab = terminalTab(for: tabID), tab.isRunning else { return }
    guard case .agent = tab.kind else { return }

    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTitle.isEmpty else {
      if tab.agentActivityState == .thinking,
        agentActivityIdleTasksByTabID[tabID] == nil
      {
        scheduleAgentActivityIdle(tabID)
      }
      return
    }

    guard tab.lastObservedTerminalTitle != normalizedTitle else { return }
    tab.lastObservedTerminalTitle = normalizedTitle
    tab.terminalSessionReconnectCount = 0
    tab.agentActivityState = .thinking
    scheduleAgentActivityIdle(tabID)
  }

  func markAgentWaitingForHuman(_ tabID: UUID) {
    guard let tab = terminalTab(for: tabID), tab.isRunning else { return }
    guard case .agent = tab.kind else { return }

    agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()
    tab.agentActivityState = .waitingForHuman
  }

  func markAgentDone(_ tabID: UUID) {
    guard let tab = terminalTab(for: tabID) else { return }
    guard case .agent = tab.kind else { return }

    agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()
    terminalAttentionVisibleClearTasksByTabID.removeValue(forKey: tabID)?.cancel()
    terminalBellTasksByTabID.removeValue(forKey: tabID)?.cancel()
    tab.hasAttention = false
    tab.isShowingBellIndicator = false
    tab.agentActivityState = .idle
    notifyRestorableStateChanged()
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

  @discardableResult
  private func clearTerminalAttentionState(_ tabID: UUID) -> Bool {
    terminalAttentionVisibleClearTasksByTabID.removeValue(forKey: tabID)?.cancel()
    guard let tab = terminalTab(for: tabID) else { return false }

    var didClear = false
    if tab.hasAttention {
      tab.hasAttention = false
      didClear = true
    }
    if tab.agentActivityState == .waitingForHuman {
      tab.agentActivityState = .idle
      didClear = true
    }
    return didClear
  }

  func closeTerminalTab(_ tabID: UUID) {
    closeTerminalTab(tabID, preserveRestorableAgentSession: false)
  }

  private func closeTerminalTab(
    _ tabID: UUID,
    preserveRestorableAgentSession: Bool
  ) {
    terminalBellTasksByTabID.removeValue(forKey: tabID)?.cancel()
    terminalAttentionVisibleClearTasksByTabID.removeValue(forKey: tabID)?.cancel()
    agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()

    for (worktreePath, tabs) in terminalTabsByWorktreePath {
      guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { continue }

      var updatedTabs = tabs
      let closingTab = updatedTabs[index]
      persistAgentSessionRestoreMetadataIfPossible(for: closingTab)
      if preserveRestorableAgentSession {
        preserveRestorableAgentTabForLater(closingTab)
      }
      TerminalSessionLifecycleLog.record(
        "close-terminal-tab tab=\(tabID.uuidString.lowercased()) preserve=\(preserveRestorableAgentSession) running=\(closingTab.isRunning) session=\(closingTab.terminalSession?.sessionID ?? "none") resume=\(closingTab.resumeSessionID ?? "none")"
      )
      if let session = closingTab.terminalSession {
        TerminalSessionLifecycleLog.record(
          "stop-terminal-session reason=close-terminal-tab tab=\(tabID.uuidString.lowercased()) session=\(session.sessionID)"
        )
        Self.terminalSessionStopper(session)
        updatedTabs[index].terminalSession = nil
      }
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

  func prepareTerminalSessionsForTermination(keepRunningAgentsAlive: Bool) {
    isPreparingForTerminalDetach = true
    TerminalSessionLifecycleLog.record(
      "prepare-terminal-sessions keep-running=\(keepRunningAgentsAlive)"
    )

    for tab in allTerminalTabs {
      guard let session = tab.terminalSession else { continue }
      let shouldKeepSessionAlive =
        keepRunningAgentsAlive && tab.shouldKeepTerminalSessionAliveAcrossQuit
      guard !shouldKeepSessionAlive else { continue }

      TerminalSessionLifecycleLog.record(
        "stop-terminal-session reason=prepare-termination tab=\(tab.id.uuidString.lowercased()) session=\(session.sessionID) keep-running-agent=\(shouldKeepSessionAlive)"
      )
      Self.terminalSessionStopper(session)
      tab.terminalSession = nil
    }
  }

  func closeThinkingAgentTabs() {
    let tabIDs = allTerminalTabs.compactMap { tab -> UUID? in
      tab.shouldWarnBeforeQuit ? tab.id : nil
    }
    for tabID in tabIDs {
      closeTerminalTab(tabID, preserveRestorableAgentSession: true)
    }
  }

  func finishTerminalDetach() {
    isPreparingForTerminalDetach = false
    TerminalSessionLifecycleLog.record("finish-terminal-detach")
  }

  @discardableResult
  func closeSelectedTerminalTab() -> Bool {
    guard let tabID = selectedTerminalTab?.id else { return false }
    closeTerminalTab(tabID)
    return true
  }

  func handleTerminalExit(_ tabID: UUID, exitBehavior: WorkspaceFinishedTerminalBehavior) {
    guard let tab = terminalTab(for: tabID) else { return }
    agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()
    TerminalSessionLifecycleLog.record(
      "handle-terminal-exit tab=\(tabID.uuidString.lowercased()) behavior=\(exitBehavior.rawValue) preparing-detach=\(isPreparingForTerminalDetach) session=\(tab.terminalSession?.sessionID ?? "none") keeps-running=\(tab.keepsRunningAfterQuit)"
    )

    if isPreparingForTerminalDetach {
      tab.isRunning = true
      TerminalSessionLifecycleLog.record(
        "handle-terminal-exit-ignored-detach tab=\(tabID.uuidString.lowercased())"
      )
      return
    }

    if reconnectPersistentTerminalSessionIfRunning(tabID, reason: "process-exit") {
      return
    }

    if let session = tab.terminalSession {
      TerminalSessionLifecycleLog.record(
        "stop-terminal-session reason=handle-terminal-exit tab=\(tabID.uuidString.lowercased()) session=\(session.sessionID)"
      )
      Self.terminalSessionStopper(session)
      tab.terminalSession = nil
    }
    persistAgentSessionRestoreMetadataIfPossible(for: tab)
    tab.isRunning = false
    tab.agentActivityState = .idle

    guard exitBehavior == .autoClose else { return }

    Task { @MainActor [weak self] in
      self?.closeTerminalTab(tabID)
    }
  }

  @discardableResult
  func recoverPersistentTerminalAttachIfExited(_ tabID: UUID, processExited: Bool) -> Bool {
    guard processExited else { return false }
    return reconnectPersistentTerminalSessionIfRunning(tabID, reason: "attach-watchdog")
  }

  @discardableResult
  private func reconnectPersistentTerminalSessionIfRunning(
    _ tabID: UUID,
    reason: String
  ) -> Bool {
    guard let tab = terminalTab(for: tabID), let session = tab.terminalSession else {
      return false
    }

    let sessionIsRunning = Self.terminalSessionRunningChecker(session)
    TerminalSessionLifecycleLog.record(
      "terminal-session-reattach-check reason=\(reason) tab=\(tabID.uuidString.lowercased()) session=\(session.sessionID) running=\(sessionIsRunning) allowed=\(tab.shouldReconnectTerminalSessionAfterAttachExit)"
    )
    guard tab.shouldReconnectTerminalSessionAfterAttachExit, sessionIsRunning else {
      return false
    }

    agentActivityIdleTasksByTabID.removeValue(forKey: tabID)?.cancel()
    tab.terminalSessionReconnectCount += 1
    tab.terminalViewIdentity = UUID()
    tab.isRunning = true
    tab.agentActivityState = .idle
    TerminalSessionLifecycleLog.record(
      "terminal-session-reattach reason=\(reason) tab=\(tabID.uuidString.lowercased()) session=\(session.sessionID) reconnects=\(tab.terminalSessionReconnectCount)"
    )
    GhosttyTerminalView.releaseTerminal(tabID)
    requestTerminalFocus(in: tab.worktreePath)
    notifyRestorableStateChanged()
    return true
  }

  private func loadSelectedWorktreeDetails(for path: String) {
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

  nonisolated private static func loadWorkspace(
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
        return (normalized, GitService.hasConflicts(repoRoot: worktree.path))
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
        || currentWorktree.createdAt != discoveredWorktree.createdAt
      {
        return true
      }
    }

    return false
  }

  nonisolated private static func loadSelectionDetails(
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

  nonisolated private static func loadRefreshedWorktree(
    for path: String,
    diffMode: WorkspaceDiffMode
  ) -> RefreshedWorktree {
    let details = loadSelectionDetails(for: path, diffMode: diffMode)
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
        if pendingTabRepresentsRunningBackgroundAgent(persistedTab) {
          restorableTabs.append(persistedTab)
          continue
        }

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

  nonisolated private static func restoreRunningBackgroundAgentTabs(
    _ persistedTabs: [PersistedWorkspaceTerminalTab]
  ) -> RestoredPersistedTabs {
    let hydratedTabs = hydratedPersistedAgentResumeMetadata(for: persistedTabs)
    return RestoredPersistedTabs(
      persistedTabs: hydratedTabs.filter(Self.pendingTabRepresentsRunningBackgroundAgent),
      missingAgentCount: 0
    )
  }

  private static func restoredTerminalTab(
    from persistedTab: PersistedWorkspaceTerminalTab
  ) -> WorkspaceTerminalTab {
    let directLaunch: TerminalLaunchConfiguration
    let kind: WorkspaceTerminalKind
    let terminalSession = terminalSessionForRestore(persistedTab)
    let launchCommandDescription =
      persistedTab.resumeCommandDescription ?? persistedTab.commandDescription

    switch persistedTab.kind {
    case .shell:
      kind = .shell
      directLaunch =
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
      directLaunch =
        persistedTab.isSandboxed
        ? TerminalLaunchConfiguration.sandboxedCommand(
          launchCommandDescription,
          currentDirectory: persistedTab.worktreePath,
          writableRoots: persistedTab.writableRoots,
          launchKind: "agent",
          agentFamily: persistedTab.agentFamilyID.map(AgentHarnesses.sandboxAgentFamily)
            ?? sandboxAgentFamily(from: persistedTab.commandDescription),
          tabID: persistedTab.id
        )
        : TerminalLaunchConfiguration.command(
          launchCommandDescription,
          currentDirectory: persistedTab.worktreePath,
          tabID: persistedTab.id
        )
    }
    let launch =
      terminalSession.map { session in
        Self.terminalSessionLaunchBuilder(session, directLaunch)
      } ?? directLaunch

    let suppressAttentionUntil: Date?
    if case .agent = kind {
      suppressAttentionUntil = Date().addingTimeInterval(
        Self.restoredAgentAttentionSuppressionInterval
      )
    } else {
      suppressAttentionUntil = nil
    }

    return WorkspaceTerminalTab(
      id: persistedTab.id,
      profileID: persistedTab.profileID,
      worktreePath: persistedTab.worktreePath,
      worktreeLabel: persistedTab.worktreeLabel,
      title: persistedTab.title,
      commandDescription: persistedTab.commandDescription,
      baseCommandDescription: persistedTab.baseCommandDescription,
      kind: kind,
      agentFamilyID: persistedTab.agentFamilyID,
      launch: launch,
      createdAt: persistedTab.createdAt,
      isSandboxed: persistedTab.isSandboxed,
      yoloMode: persistedTab.yoloMode,
      yoloFlag: Self.yoloFlag(for: persistedTab),
      writableRoots: persistedTab.writableRoots,
      isRestorableAfterRelaunch: true,
      resumeArgumentTemplate: persistedTab.resumeArgumentTemplate,
      keepsRunningAfterQuit: Self.restoredKeepsRunningAfterQuit(
        persistedTab: persistedTab,
        kind: kind,
        terminalSession: terminalSession
      ),
      terminalSession: terminalSession,
      resumeSessionID: persistedTab.resumeSessionID,
      resumeCommandDescription: persistedTab.resumeCommandDescription,
      hasAttention: persistedTab.hasAttention,
      agentActivityState: persistedTab.agentActivityState,
      suppressAttentionUntil: suppressAttentionUntil
    )
  }

  private static func terminalSessionForRestore(_ tab: PersistedWorkspaceTerminalTab)
    -> TerminalSessionReference?
  {
    guard AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence else {
      if let terminalSession = tab.terminalSession {
        TerminalSessionLifecycleLog.record(
          "stop-terminal-session reason=restore-experiment-off tab=\(tab.id.uuidString.lowercased()) session=\(terminalSession.sessionID)"
        )
        Self.terminalSessionStopper(terminalSession)
      }
      return nil
    }
    if let terminalSession = tab.terminalSession {
      let canReconnect = Self.terminalSessionReconnectChecker(terminalSession)
      let wasPreserved = TerminalSessionBackends.wasPreservedForRestore(
        reference: terminalSession)
      let isRunning = canReconnect && Self.terminalSessionRunningChecker(terminalSession)
      guard canReconnect, wasPreserved || isRunning
      else {
        TerminalSessionLifecycleLog.record(
          "stop-terminal-session reason=restore-unusable-existing tab=\(tab.id.uuidString.lowercased()) session=\(terminalSession.sessionID)"
        )
        Self.terminalSessionStopper(terminalSession)
        return replacementTerminalSessionForRestore(tab)
      }
      return terminalSession
    }
    let replacementSession = replacementTerminalSessionForRestore(tab)
    if let replacementSession {
      // The replacement ID is deterministic for the restored tab. Clear any stale
      // server so attach recreates it with the hydrated resume command.
      TerminalSessionLifecycleLog.record(
        "stop-terminal-session reason=restore-clear-replacement tab=\(tab.id.uuidString.lowercased()) session=\(replacementSession.sessionID)"
      )
      Self.terminalSessionStopper(replacementSession)
    }
    return replacementSession
  }

  private static func replacementTerminalSessionForRestore(_ tab: PersistedWorkspaceTerminalTab)
    -> TerminalSessionReference?
  {
    guard AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence else {
      return nil
    }
    guard case .agent = tab.kind else { return nil }
    guard tab.keepsRunningAfterQuit || tab.terminalSession != nil else { return nil }
    return Self.terminalSessionReferenceProvider(tab.id, tab.worktreePath)
  }

  private static func restoredKeepsRunningAfterQuit(
    persistedTab: PersistedWorkspaceTerminalTab,
    kind: WorkspaceTerminalKind,
    terminalSession: TerminalSessionReference?
  ) -> Bool {
    guard case .agent = kind else {
      return persistedTab.keepsRunningAfterQuit
    }
    return persistedTab.keepsRunningAfterQuit || terminalSession != nil
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
        profileID: tab.profileID,
        worktreePath: tab.worktreePath,
        worktreeLabel: tab.worktreeLabel,
        title: tab.title,
        commandDescription: tab.commandDescription,
        baseCommandDescription: tab.baseCommandDescription,
        kind: tab.kind,
        agentFamilyID: tab.agentFamilyID,
        createdAt: tab.createdAt,
        isSandboxed: tab.isSandboxed,
        yoloMode: tab.yoloMode,
        writableRoots: tab.writableRoots,
        resumeArgumentTemplate: tab.resumeArgumentTemplate,
        keepsRunningAfterQuit: tab.keepsRunningAfterQuit,
        terminalSession: tab.terminalSession,
        resumeSessionID: tab.resumeSessionID,
        resumeCommandDescription: renderedResumeCommand,
        hasAttention: tab.hasAttention,
        agentActivityState: tab.agentActivityState
      )
    }

    var unresolvedGroups: [AgentResumeHydrationGroup: [Int]] = [:]
    for index in hydratedTabs.indices {
      let tab = hydratedTabs[index]
      guard case .agent = tab.kind else { continue }
      guard tab.resumeCommandDescription == nil else { continue }
      guard tab.resumeArgumentTemplate.contains("{{session_id}}") else { continue }
      guard let familyID = agentFamilyIDForResumeHydration(tab) else { continue }

      let group = AgentResumeHydrationGroup(
        familyID: familyID,
        worktreePath: normalizedPath(tab.worktreePath)
      )
      unresolvedGroups[group, default: []].append(index)
    }

    guard !unresolvedGroups.isEmpty else { return hydratedTabs }

    let earliestCreatedAt =
      unresolvedGroups.values
      .flatMap { $0 }
      .compactMap { hydratedTabs[$0].createdAt }
      .min()
      ?? .distantPast
    let sessionLookup = resumeSessionsByHydrationGroup(
      familyIDs: Set(unresolvedGroups.keys.map(\.familyID)),
      notBefore: earliestCreatedAt.addingTimeInterval(-3600)
    )

    for (group, indices) in unresolvedGroups {
      guard !indices.isEmpty else { continue }
      guard var sessions = sessionLookup[group], !sessions.isEmpty else {
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
          guard normalizedTabWorktreePath == group.worktreePath else { return nil }
          guard agentFamilyIDForResumeHydration(tab) == group.familyID else { return nil }
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
              profileID: tab.profileID,
              worktreePath: tab.worktreePath,
              worktreeLabel: tab.worktreeLabel,
              title: tab.title,
              commandDescription: tab.commandDescription,
              baseCommandDescription: tab.baseCommandDescription,
              kind: tab.kind,
              agentFamilyID: tab.agentFamilyID,
              createdAt: tab.createdAt,
              isSandboxed: tab.isSandboxed,
              yoloMode: tab.yoloMode,
              writableRoots: tab.writableRoots,
              resumeArgumentTemplate: tab.resumeArgumentTemplate,
              keepsRunningAfterQuit: tab.keepsRunningAfterQuit,
              terminalSession: tab.terminalSession,
              resumeSessionID: tabSessionID,
              resumeCommandDescription: renderedResumeCommand,
              hasAttention: tab.hasAttention,
              agentActivityState: tab.agentActivityState
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
          profileID: tab.profileID,
          worktreePath: tab.worktreePath,
          worktreeLabel: tab.worktreeLabel,
          title: tab.title,
          commandDescription: tab.commandDescription,
          baseCommandDescription: tab.baseCommandDescription,
          kind: tab.kind,
          agentFamilyID: tab.agentFamilyID,
          createdAt: tab.createdAt,
          isSandboxed: tab.isSandboxed,
          yoloMode: tab.yoloMode,
          writableRoots: tab.writableRoots,
          resumeArgumentTemplate: tab.resumeArgumentTemplate,
          keepsRunningAfterQuit: tab.keepsRunningAfterQuit,
          terminalSession: tab.terminalSession,
          resumeSessionID: matchingSession.sessionID,
          resumeCommandDescription: renderedResumeCommand,
          hasAttention: tab.hasAttention,
          agentActivityState: tab.agentActivityState
        )
      }
    }

    return hydratedTabs
  }

  nonisolated private static func agentFamilyIDForResumeHydration(
    _ tab: PersistedWorkspaceTerminalTab
  ) -> AgentFamilyID? {
    tab.agentFamilyID ?? AgentHarnesses.familyID(matchingCommand: tab.commandDescription)
  }

  nonisolated private static func yoloFlag(for tab: PersistedWorkspaceTerminalTab) -> String {
    guard case .agent = tab.kind else { return "" }
    guard
      let familyID = tab.agentFamilyID
        ?? AgentHarnesses.familyID(
          matchingCommand: tab.baseCommandDescription
        )
    else { return "" }
    return familyID.defaultProfile.yoloFlag
  }

  nonisolated private static func resumeSessionsByHydrationGroup(
    familyIDs: Set<AgentFamilyID>,
    notBefore: Date
  ) -> [AgentResumeHydrationGroup: [AgentResumeSessionRecord]] {
    var groupedSessions: [AgentResumeHydrationGroup: [AgentResumeSessionRecord]] = [:]
    for familyID in familyIDs {
      for session in AgentHarnesses.resumeSessionRecords(for: familyID, notBefore: notBefore) {
        let group = AgentResumeHydrationGroup(
          familyID: familyID,
          worktreePath: normalizedPath(session.cwd)
        )
        groupedSessions[group, default: []].append(session)
      }
    }
    return groupedSessions
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

    let terminalSession = tab.terminalSession.map { session in
      tab.shouldKeepTerminalSessionAliveAcrossQuit
        ? TerminalSessionBackends.markPreservedForRestore(reference: session)
        : session
    }

    return PersistedWorkspaceTerminalTab(
      id: tab.id,
      profileID: tab.profileID,
      worktreePath: tab.worktreePath,
      worktreeLabel: tab.worktreeLabel,
      title: tab.title,
      commandDescription: tab.commandDescription,
      baseCommandDescription: tab.baseCommandDescription,
      kind: kind,
      agentFamilyID: tab.agentFamilyID,
      createdAt: tab.createdAt,
      isSandboxed: tab.isSandboxed,
      yoloMode: tab.yoloMode,
      writableRoots: tab.writableRoots,
      resumeArgumentTemplate: tab.resumeArgumentTemplate,
      keepsRunningAfterQuit: tab.keepsRunningAfterQuit,
      terminalSession: terminalSession,
      resumeSessionID: tab.resumeSessionID,
      resumeCommandDescription: tab.resumeCommandDescription,
      hasAttention: tab.hasAttention,
      agentActivityState: tab.agentActivityState
    )
  }

  nonisolated private static func persistedTabByResolvingResumeTemplate(
    from tab: PersistedWorkspaceTerminalTab,
    using restoreMetadataByProfileIDOrName: [String: AgentRestoreProfileMetadata]
  ) -> PersistedWorkspaceTerminalTab {
    guard case .agent(let profileName, _) = tab.kind else { return tab }
    let metadata =
      tab.profileID.flatMap { restoreMetadataByProfileIDOrName[$0] }
      ?? restoreMetadataByProfileIDOrName[profileName]
    let resumeArgumentTemplate = metadata?.resumeArgumentTemplate ?? ""
    guard
      resumeArgumentTemplate != tab.resumeArgumentTemplate
    else { return tab }

    return PersistedWorkspaceTerminalTab(
      id: tab.id,
      profileID: tab.profileID,
      worktreePath: tab.worktreePath,
      worktreeLabel: tab.worktreeLabel,
      title: tab.title,
      commandDescription: tab.commandDescription,
      baseCommandDescription: tab.baseCommandDescription,
      kind: tab.kind,
      agentFamilyID: tab.agentFamilyID,
      createdAt: tab.createdAt,
      isSandboxed: tab.isSandboxed,
      yoloMode: tab.yoloMode,
      writableRoots: tab.writableRoots,
      resumeArgumentTemplate: resumeArgumentTemplate,
      keepsRunningAfterQuit: tab.keepsRunningAfterQuit,
      terminalSession: tab.terminalSession,
      resumeSessionID: tab.resumeSessionID,
      resumeCommandDescription: tab.resumeCommandDescription,
      hasAttention: tab.hasAttention,
      agentActivityState: tab.agentActivityState
    )
  }

  private func refreshPendingAgentActivitySummaries() {
    let worktreePaths = Set(
      Array(pendingRestorableTabsByWorktreePath.keys)
        + Array(pendingAgentActivitySummariesByWorktreePath.keys)
    )
    for worktreePath in worktreePaths {
      refreshPendingAgentActivitySummary(for: worktreePath)
    }
  }

  private func refreshPendingAgentActivitySummary(for worktreePath: String) {
    let normalizedPath = normalizedPath(worktreePath)
    let summary = Self.pendingAgentActivitySummary(
      for: pendingRestorableTabsByWorktreePath[normalizedPath] ?? []
    )

    if summary == .empty {
      pendingAgentActivitySummariesByWorktreePath.removeValue(forKey: normalizedPath)
    } else {
      pendingAgentActivitySummariesByWorktreePath[normalizedPath] = summary
    }
  }

  private func pendingRunningBackgroundAgentCount() -> Int {
    pendingRestorableTabsByWorktreePath.values.reduce(0) { count, tabs in
      count + tabs.filter(Self.pendingTabRepresentsRunningBackgroundAgent).count
    }
  }

  nonisolated private static func pendingAgentActivitySummary(
    for tabs: [PersistedWorkspaceTerminalTab]
  ) -> WorktreeAgentActivitySummary {
    tabs.reduce(into: .empty) { summary, tab in
      guard pendingTabRepresentsRunningBackgroundAgent(tab) else { return }
      let isWaitingForHuman = tab.hasAttention || tab.agentActivityState == .waitingForHuman

      summary = WorktreeAgentActivitySummary(
        waitingForHumanCount: summary.waitingForHumanCount + (isWaitingForHuman ? 1 : 0),
        thinkingCount: summary.thinkingCount
          + (tab.agentActivityState == .thinking ? 1 : 0),
        runningAgentCount: summary.runningAgentCount + 1
      )
    }
  }

  nonisolated private static func pendingTabRepresentsRunningBackgroundAgent(
    _ tab: PersistedWorkspaceTerminalTab
  ) -> Bool {
    guard case .agent = tab.kind else { return false }
    guard AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence else {
      return false
    }
    guard let terminalSession = tab.terminalSession else { return false }
    guard terminalSessionReconnectChecker(terminalSession) else { return false }
    return terminalSessionRunningChecker(terminalSession)
  }

  private static func restoreMetadataByProfileIDOrName(savedProfiles: [SavedAgentProfile])
    -> [String: AgentRestoreProfileMetadata]
  {
    var metadataByProfileIDOrName: [String: AgentRestoreProfileMetadata] = [:]

    for profile in SavedAgentProfiles.builtinDefaults {
      let metadata = AgentRestoreProfileMetadata(profile: profile)
      metadataByProfileIDOrName[profile.id] = metadata
      metadataByProfileIDOrName[profile.name] = metadata
    }

    for profile in savedProfiles {
      let metadata = AgentRestoreProfileMetadata(profile: profile)
      metadataByProfileIDOrName[profile.id] = metadata
      metadataByProfileIDOrName[profile.name] = metadata
    }

    return metadataByProfileIDOrName
  }

  private static func agentProfilesByID(savedProfiles: [SavedAgentProfile])
    -> [String: SavedAgentProfile]
  {
    var profilesByID = Dictionary(
      uniqueKeysWithValues: SavedAgentProfiles.builtinDefaults.map { profile in
        (profile.id, profile)
      }
    )

    for profile in savedProfiles {
      profilesByID[profile.id] = profile
    }

    return profilesByID
  }

  private static func sessionSpecificResumeArgumentTemplate(
    for familyID: AgentFamilyID,
    profile: SavedAgentProfile
  ) -> String {
    switch familyID {
    case .claudeCode, .gemini:
      "--resume {{session_id}}"
    case .codex:
      profile.resumeArgumentTemplate.isEmpty
        ? familyID.defaultProfile.resumeArgumentTemplate
        : profile.resumeArgumentTemplate
    }
  }

  private static func agentCommand(
    baseCommand: String,
    yoloMode: Bool,
    yoloFlag: String
  ) -> String {
    let command = baseCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    let flag = yoloFlag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard yoloMode, !flag.isEmpty else { return command }
    guard !command.hasSuffix(" \(flag)") else { return command }
    return "\(command) \(flag)"
  }

  private static func agentSessionKey(
    familyID: AgentFamilyID,
    sessionID: String
  ) -> String {
    "\(familyID.rawValue):\(sessionID)"
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

  private func startPendingTabRestoreIfNeeded(for worktreePath: String) {
    let normalizedPath = normalizedPath(worktreePath)
    guard pendingTabRestoreTasksByWorktreePath[normalizedPath] == nil,
      let persistedTabs = pendingRestorableTabsByWorktreePath.removeValue(forKey: normalizedPath),
      !persistedTabs.isEmpty
    else {
      return
    }

    refreshPendingAgentActivitySummary(for: normalizedPath)

    startPendingTabRestoreTask(
      for: normalizedPath,
      persistedTabs: persistedTabs,
      removeRestoredTabsFromPending: false
    )
  }

  private func startRunningBackgroundAgentRestores(
    validPaths: Set<String>,
    excluding selectedWorktreePath: String?
  ) {
    let selectedWorktreePath = selectedWorktreePath.map(normalizedPath)
    for worktreePath in pendingRestorableTabsByWorktreePath.keys.sorted() {
      let normalizedPath = normalizedPath(worktreePath)
      guard validPaths.contains(normalizedPath), normalizedPath != selectedWorktreePath else {
        continue
      }
      startPendingRunningBackgroundAgentRestoreIfNeeded(for: normalizedPath)
    }
  }

  private func startPendingRunningBackgroundAgentRestoreIfNeeded(for worktreePath: String) {
    let normalizedPath = normalizedPath(worktreePath)
    guard pendingTabRestoreTasksByWorktreePath[normalizedPath] == nil,
      let persistedTabs = pendingRestorableTabsByWorktreePath[normalizedPath],
      !persistedTabs.isEmpty
    else {
      return
    }

    let runningAgentTabs = persistedTabs.filter(Self.pendingTabRepresentsRunningBackgroundAgent)
    guard !runningAgentTabs.isEmpty else {
      refreshPendingAgentActivitySummary(for: normalizedPath)
      return
    }

    refreshPendingAgentActivitySummary(for: normalizedPath)

    startPendingTabRestoreTask(
      for: normalizedPath,
      persistedTabs: runningAgentTabs,
      removeRestoredTabsFromPending: true
    )
  }

  private func startPendingTabRestoreTask(
    for normalizedPath: String,
    persistedTabs: [PersistedWorkspaceTerminalTab],
    removeRestoredTabsFromPending: Bool
  ) {
    pendingTabRestoreTasksByWorktreePath[normalizedPath] = Task { @MainActor [weak self] in
      if let delay = Self.tabRestoreTestDelay {
        try? await Task.sleep(for: delay)
      }
      let restored = await Task.detached {
        if removeRestoredTabsFromPending {
          return Self.restoreRunningBackgroundAgentTabs(persistedTabs)
        }
        return Self.restorePersistedTabs(persistedTabs)
      }.value

      guard let self, !Task.isCancelled else { return }
      self.pendingTabRestoreTasksByWorktreePath.removeValue(forKey: normalizedPath)
      self.applyRestoredPersistedTabs(
        restored,
        for: normalizedPath,
        removeRestoredTabsFromPending: removeRestoredTabsFromPending
      )
    }
  }

  @discardableResult
  private func materializePendingRunningAgentTabs(for worktreePath: String) -> Bool {
    let normalizedPath = normalizedPath(worktreePath)
    guard pendingTabRestoreTasksByWorktreePath[normalizedPath] == nil,
      let persistedTabs = pendingRestorableTabsByWorktreePath[normalizedPath],
      !persistedTabs.isEmpty
    else {
      return false
    }

    let restored = Self.restoreRunningBackgroundAgentTabs(persistedTabs)
    guard !restored.persistedTabs.isEmpty else {
      refreshPendingAgentActivitySummary(for: normalizedPath)
      return false
    }

    applyRestoredPersistedTabs(
      restored,
      for: normalizedPath,
      removeRestoredTabsFromPending: true
    )
    return true
  }

  private func applyRestoredPersistedTabs(
    _ restored: RestoredPersistedTabs,
    for normalizedPath: String,
    removeRestoredTabsFromPending: Bool
  ) {
    let restoredTabs = restored.persistedTabs.map(Self.restoredTerminalTab(from:))
    let currentTabs = terminalTabsByWorktreePath[normalizedPath] ?? []
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

    terminalTabsByWorktreePath[normalizedPath] = mergedTabs
    if removeRestoredTabsFromPending {
      let restoredTabIDs = Set(restored.persistedTabs.map(\.id))
      var pendingTabs = pendingRestorableTabsByWorktreePath[normalizedPath] ?? []
      pendingTabs.removeAll { restoredTabIDs.contains($0.id) }
      if pendingTabs.isEmpty {
        pendingRestorableTabsByWorktreePath.removeValue(forKey: normalizedPath)
      } else {
        pendingRestorableTabsByWorktreePath[normalizedPath] = pendingTabs
      }
      refreshPendingAgentActivitySummary(for: normalizedPath)
    }
    let pendingTabs = pendingRestorableTabsByWorktreePath[normalizedPath] ?? []

    if let selectedTabID = selectedTerminalTabIDsByWorktreePath[normalizedPath],
      !mergedTabs.contains(where: { $0.id == selectedTabID })
    {
      if !pendingTabs.contains(where: { $0.id == selectedTabID }) {
        selectedTerminalTabIDsByWorktreePath[normalizedPath] = mergedTabs.first?.id
      }
    } else if selectedTerminalTabIDsByWorktreePath[normalizedPath] == nil
      && pendingTabs.isEmpty
    {
      selectedTerminalTabIDsByWorktreePath[normalizedPath] = mergedTabs.first?.id
    }

    if normalizedSelectedWorktreePath == normalizedPath {
      if selectedTerminalTabIDsByWorktreePath[normalizedPath] != nil {
        requestTerminalFocus(in: normalizedPath)
      } else {
        terminalFocusRequestIDsByWorktreePath.removeValue(forKey: normalizedPath)
      }
    }

    if restored.missingAgentCount > 0 {
      restoreFailureMessage = Self.formattedRestoreFailureMessage(
        missingAgentCount: restored.missingAgentCount,
        worktreeLabel: restoredWorktreeLabel(for: normalizedPath)
      )
    }

    notifyRestorableStateChanged()
    if normalizedSelectedWorktreePath == normalizedPath,
      pendingRestorableTabsByWorktreePath[normalizedPath]?.isEmpty == false
    {
      startPendingTabRestoreIfNeeded(for: normalizedPath)
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
      terminalAttentionVisibleClearTasksByTabID.removeValue(forKey: tab.id)?.cancel()
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

  private func pruneWorktreeState(validPaths: Set<String>) {
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
    let diffMode = effectiveDiffMode(for: path)
    let result = await Task.detached {
      Self.loadRefreshedWorktree(for: path, diffMode: diffMode)
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

  private func persistAgentSessionRestoreMetadataIfPossible(for tab: WorkspaceTerminalTab) {
    guard let sessionID = tab.resumeSessionID ?? hydrateAgentResumeSessionID(for: tab) else {
      return
    }

    tab.resumeSessionID = sessionID
    recordAgentSessionRestoreMetadata(for: tab, sessionID: sessionID)
  }

  private func preserveRestorableAgentTabForLater(_ tab: WorkspaceTerminalTab) {
    guard let persistedTab = stoppedRestorableAgentTab(from: tab) else { return }
    let worktreePath = normalizedPath(tab.worktreePath)
    var pendingTabs = pendingRestorableTabsByWorktreePath[worktreePath] ?? []
    pendingTabs.removeAll { $0.id == persistedTab.id }
    pendingTabs.append(persistedTab)
    pendingRestorableTabsByWorktreePath[worktreePath] = pendingTabs
    refreshPendingAgentActivitySummary(for: worktreePath)
  }

  private func stoppedRestorableAgentTab(
    from tab: WorkspaceTerminalTab
  ) -> PersistedWorkspaceTerminalTab? {
    guard tab.isRestorableAfterRelaunch else { return nil }
    let kind: PersistedWorkspaceTerminalTabKind
    switch tab.kind {
    case .shell:
      return nil
    case .agent(let profileName, let icon):
      kind = .agent(profileName: profileName, icon: icon)
    }
    guard !tab.resumeArgumentTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    let resumeCommandDescription =
      tab.resumeCommandDescription
      ?? renderAgentResumeCommand(
        baseCommand: tab.commandDescription,
        resumeArgumentTemplate: tab.resumeArgumentTemplate,
        sessionID: tab.resumeSessionID
      )

    return PersistedWorkspaceTerminalTab(
      id: tab.id,
      profileID: tab.profileID,
      worktreePath: tab.worktreePath,
      worktreeLabel: tab.worktreeLabel,
      title: tab.title,
      commandDescription: tab.commandDescription,
      baseCommandDescription: tab.baseCommandDescription,
      kind: kind,
      agentFamilyID: tab.agentFamilyID,
      createdAt: tab.createdAt,
      isSandboxed: tab.isSandboxed,
      yoloMode: tab.yoloMode,
      writableRoots: tab.writableRoots,
      resumeArgumentTemplate: tab.resumeArgumentTemplate,
      keepsRunningAfterQuit: tab.keepsRunningAfterQuit,
      terminalSession: nil,
      resumeSessionID: tab.resumeSessionID,
      resumeCommandDescription: resumeCommandDescription,
      hasAttention: tab.hasAttention,
      agentActivityState: tab.agentActivityState
    )
  }

  private func hydrateAgentResumeSessionID(for tab: WorkspaceTerminalTab) -> String? {
    if let sessionID = tab.resumeSessionID, !sessionID.isEmpty {
      return sessionID
    }
    guard case .agent = tab.kind else { return nil }
    guard
      let familyID = tab.agentFamilyID
        ?? AgentHarnesses.familyID(
          matchingCommand: tab.baseCommandDescription
        )
    else { return nil }

    let worktreePath = normalizedPath(tab.worktreePath)
    let usedSessionIDs = Set(
      allTerminalTabs.compactMap { otherTab -> String? in
        guard otherTab.id != tab.id else { return nil }
        guard normalizedPath(otherTab.worktreePath) == worktreePath else { return nil }
        return otherTab.resumeSessionID
      }
    )
    let sessions =
      AgentHarnesses.resumeSessionRecords(
        for: familyID,
        notBefore: tab.createdAt.addingTimeInterval(-120)
      )
      .filter {
        normalizedPath($0.cwd) == worktreePath && !usedSessionIDs.contains($0.sessionID)
      }
      .sorted {
        if $0.startedAt == $1.startedAt {
          return $0.sessionID < $1.sessionID
        }
        return $0.startedAt < $1.startedAt
      }

    return sessions.first { $0.startedAt >= tab.createdAt.addingTimeInterval(-120) }?.sessionID
      ?? sessions.first?.sessionID
  }

  private func recordAgentSessionRestoreMetadata(
    for tab: WorkspaceTerminalTab,
    sessionID: String,
    profileID: String? = nil,
    yoloMode: Bool? = nil,
    sandboxEnabled: Bool? = nil
  ) {
    guard !sessionID.isEmpty else { return }
    guard case .agent = tab.kind else { return }
    guard tab.isRestorableAfterRelaunch else { return }
    guard
      let familyID = tab.agentFamilyID
        ?? AgentHarnesses.familyID(
          matchingCommand: tab.baseCommandDescription
        )
    else { return }
    guard !tab.resumeArgumentTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    AgentSessionRestoreMetadataStore.record(
      AgentSessionRestoreMetadata(
        familyID: familyID,
        profileID: profileID ?? tab.profileID,
        sessionID: sessionID,
        cwd: tab.worktreePath,
        yoloMode: yoloMode ?? tab.yoloMode,
        sandboxEnabled: sandboxEnabled ?? tab.isSandboxed,
        updatedAt: Date()
      )
    )
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
    // Base-worktree updates for sandboxed finalizers are brokered through Argon.
    // Only direct writes in the linked worktree need to be present on the tab.
    let requiredRoots = requiredDirectWritableRoots(for: action).map(normalizedPath)

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
    sourceTabID: UUID?,
    sourceSandboxed: Bool? = nil
  ) throws -> String {
    let request = try finalizeControlRequest(for: action)
    let pendingRequest = try beginAgentControlRequest(
      request,
      worktreePath: request.worktreePath,
      sourceTabID: sourceTabID
    )
    return try request.promptWithResponseContract(responseFilePath: pendingRequest.responseFilePath)
      + finalizeSandboxBrokerInstructions(
        for: action,
        sourceTabID: sourceTabID,
        sourceSandboxed: sourceSandboxed
      )
  }

  private func finalizeSandboxBrokerInstructions(
    for action: WorktreeFinalizeAction,
    sourceTabID: UUID?,
    sourceSandboxed: Bool?
  ) -> String {
    guard action.requiresBaseRepoWriteAccess else { return "" }

    let tabIsSandboxed =
      sourceSandboxed
      ?? sourceTabID
      .flatMap { terminalTab(for: $0) }?
      .isSandboxed
    guard tabIsSandboxed == true else { return "" }
    let worktreePath = selectedWorktree?.path ?? "the linked worktree"

    return """

      Sandboxed finalize note:
      - If this tab is sandboxed, do not treat base worktree write denial as a reason to launch another agent.
      - Make linked-worktree changes directly in \(worktreePath).
      - Use the Argon sandbox broker exposed by this terminal for operations that update the base worktree at \(target.repoRoot).
      - If the broker is unavailable or rejects the operation, report `status: "failed"` with the broker error.
      """
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
      compareURL: selectedPullRequestURL,
      commitBeforeLanding: action.isMergeBackAction && selectedBranchTopology?.aheadCount == 0
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
        action: action,
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
    action: WorktreeFinalizeAction,
    status: WorkspaceAgentControlStatus,
    message: String,
    pullRequestURL: String?,
    followUp: String?,
    pendingRequest: PendingWorkspaceAgentControlRequest
  ) {
    switch status {
    case .success:
      if action.isMergeBackAction {
        completedMergeBackWorktreePaths.insert(pendingRequest.worktreePath)
        if let sourceTabID = pendingRequest.sourceTabID {
          markAgentDone(sourceTabID)
        }
      }
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
    let normalizedWorktreePath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-agent-control", isDirectory: true)
      .appendingPathComponent("w-\(pathHash(normalizedWorktreePath))", isDirectory: true)
  }

  nonisolated private static func pathHash(_ path: String) -> String {
    String(format: "%016llx", fnv1a64(Array(path.utf8)))
  }

  nonisolated private static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return hash
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

  private func requiredDirectWritableRoots(for _: WorktreeFinalizeAction) -> [String] {
    guard let selectedWorktree else { return [target.repoRoot] }
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

  private static func worktreeRemovalErrorMessage(
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

  private func resolvedInventorySelectionPath(
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

  private func nearestInventorySelectionPath(
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

struct WorkspaceErrorDialog: Identifiable, Equatable, Sendable {
  let id = UUID()
  let title: String
  let message: String
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

private struct AgentResumeHydrationGroup: Hashable, Sendable {
  let familyID: AgentFamilyID
  let worktreePath: String
}

private struct AgentRestoreProfileMetadata: Sendable {
  let resumeArgumentTemplate: String

  init(profile: SavedAgentProfile) {
    self.resumeArgumentTemplate = profile.resumeArgumentTemplate
  }
}

struct WorkspaceRestorableAgentSession: Identifiable, Hashable, Sendable {
  let familyID: AgentFamilyID
  let profileID: String
  let profileName: String
  let command: String
  let icon: String
  let resumeArgumentTemplate: String
  let sessionID: String
  let cwd: String
  let yoloMode: Bool
  let sandboxEnabled: Bool
  let startedAt: Date
  let openStoppedTabID: UUID?

  var id: String {
    "\(familyID.rawValue):\(sessionID):\(cwd)"
  }

  var yoloFlag: String {
    familyID.defaultProfile.yoloFlag
  }
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

private struct WorktreeRemovalBranchDetails: Sendable {
  let hasUncommittedChanges: Bool
  let hasInitializedSubmodules: Bool
  let submodulesWithUnpushedCommits: [SubmoduleUnpushedCommits]
  let branchName: String?
  let canDeleteBranch: Bool
  let branchComparisonBaseRef: String?
  let branchHasUniqueCommits: Bool
  let branchHasUnpushedCommits: Bool
}
