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
  static let restoredAgentAttentionSuppressionInterval: TimeInterval = 3
  nonisolated(unsafe) static var sandboxfilePromptLoader:
    (@Sendable (String, SandboxfileLaunchKind) async throws -> SandboxfilePromptRequest?) = {
      repoRoot,
      launchKind in
      try await loadSandboxfilePromptIfNeeded(repoRoot: repoRoot, launchKind: launchKind)
    }
  nonisolated(unsafe) static var sandboxfileCreator:
    (@Sendable (SandboxfilePromptRequest, SandboxfileWizardConfiguration) async throws -> Void) = {
      request,
      configuration in
      try await createRepoSandboxfile(request: request, configuration: configuration)
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
  var isPresentingNewWorktreeSheet = false
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
  let worktreeRootPathProvider: () -> String

  var commonDirWatcher: FileWatcher?
  var worktreeWatchersByPath: [String: FileWatcher] = [:]
  var workspaceReloadTask: Task<Void, Never>?
  var worktreeRefreshTasksByPath: [String: Task<Void, Never>] = [:]
  var pendingSandboxedShellLaunchCount = 0
  var isResolvingSandboxedShellLaunch = false
  var terminalBellTasksByTabID: [UUID: Task<Void, Never>] = [:]
  var terminalAttentionVisibleClearTasksByTabID: [UUID: Task<Void, Never>] = [:]
  var agentActivityIdleTasksByTabID: [UUID: Task<Void, Never>] = [:]
  var activeAgentControlRequestsByID: [UUID: PendingWorkspaceAgentControlRequest] = [:]
  var agentControlWatchTasksByRequestID: [UUID: Task<Void, Never>] = [:]
  var activeLocalMergeBackWorktreePaths: Set<String> = []
  var pendingRestorableTabsByWorktreePath: [String: [PersistedWorkspaceTerminalTab]] = [:]
  var pendingTabRestoreTasksByWorktreePath: [String: Task<Void, Never>] = [:]
  var pendingAgentActivitySummariesByWorktreePath: [String: WorktreeAgentActivitySummary] =
    [:]
  var selectionLoadRequestID: UUID?
  var shouldLaunchReviewAfterNextAgentTab = false
  var pendingReviewPreparationAfterAgentLaunch: WorkspaceReviewPreparation?
  var stagedReviewLaunch: StagedReviewLaunch?
  var preparedReviewTargetsByAgentTabID: [UUID: ReviewTarget] = [:]
  var didApplyUITestWebsiteDemo = false
  var isPreparingForTerminalDetach = false
  @ObservationIgnored
  nonisolated(unsafe) var reviewSessionCloseObserver: NSObjectProtocol?
  @ObservationIgnored
  nonisolated(unsafe) var reviewSessionUpdateObserver: NSObjectProtocol?

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
    reviewSessionUpdateObserver = NotificationCenter.default.addObserver(
      forName: .reviewSessionDidUpdate,
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
    if let reviewSessionUpdateObserver {
      NotificationCenter.default.removeObserver(reviewSessionUpdateObserver)
    }
  }

  var repoName: String {
    URL(fileURLWithPath: target.repoRoot).lastPathComponent
  }

  var selectedWorktreeLabel: String? {
    guard let selectedWorktree else { return nil }
    return selectedWorktree.displayName
  }

  var windowTitle: String {
    guard let selectedWorktreeLabel, selectedWorktreeLabel != repoName else {
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
    return Self.supportsAllChangesDiff(for: selectedWorktree)
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
    canFinalizeSelectedWorktree
      && (selectedSummary.hasChanges || ((selectedBranchTopology?.aheadCount ?? 0) > 0))
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
}
