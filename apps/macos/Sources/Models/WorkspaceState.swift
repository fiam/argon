import Foundation

@MainActor
@Observable
final class WorkspaceState {
  nonisolated(unsafe) static var tabRestoreTestDelay: Duration?

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
  var selectedBranchTopology: BranchTopology?
  var selectedUpdatedAt: Date?
  var errorMessage: String?
  var launchWarningMessage: String?
  var restoreFailureMessage: String?
  var isLoadingSelectionDetails = false
  var isLoading = false
  var isLaunchingReview = false
  var isCreatingWorktree = false
  var isRemovingWorktree = false
  var isPresentingTabCreationSheet = false
  var isPresentingAgentLaunchSheet = false
  var isPresentingReviewAgentPicker = false
  var isPresentingFinalizeAgentPicker = false
  var isPresentingMergeBackOptions = false
  var reviewAgentCandidates: [WorkspaceTerminalTab] = []
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
  private var pendingRestorableTabsByWorktreePath: [String: [PersistedWorkspaceTerminalTab]] = [:]
  private var pendingTabRestoreTasksByWorktreePath: [String: Task<Void, Never>] = [:]
  private var selectionLoadRequestID: UUID?
  private var shouldLaunchReviewAfterNextAgentTab = false
  private var stagedReviewLaunch: StagedReviewLaunch?
  private var preparedReviewTargetsByAgentTabID: [UUID: ReviewTarget] = [:]
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
    return reviewSnapshotsByWorktreePath[path]
  }

  var selectedTerminalFocusRequestID: UUID? {
    guard let path = normalizedSelectedWorktreePath else { return nil }
    return terminalFocusRequestIDsByWorktreePath[path]
  }

  var canSeedFromPersistedWindowSnapshot: Bool {
    worktrees.isEmpty
      && worktreeSummaries.isEmpty
      && reviewSnapshotsByWorktreePath.isEmpty
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

    let terminalTabsByWorktreePath =
      pendingRestorableTabsByWorktreePath.merging(
        terminalTabsByWorktreePath.reduce(into: [String: [PersistedWorkspaceTerminalTab]]()) {
          partialResult, entry in
          let persistedTabs = entry.value.compactMap { tab -> PersistedWorkspaceTerminalTab? in
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
              writableRoots: tab.writableRoots
            )
          }

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
      selectedTerminalTabIDsByWorktreePath: selectedTerminalTabIDsByWorktreePath
    )
  }

  func applyPersistedWindowSnapshot(_ snapshot: PersistedWorkspaceWindowSnapshot) {
    selectedWorktreePath = normalizedPath(snapshot.target.selectedWorktreePath ?? target.repoRoot)
    terminalTabsByWorktreePath = [:]
    pendingRestorableTabsByWorktreePath = snapshot.terminalTabsByWorktreePath.reduce(
      into: [String: [PersistedWorkspaceTerminalTab]]()
    ) { partialResult, entry in
      partialResult[normalizedPath(entry.key)] = entry.value.map { tab in
        PersistedWorkspaceTerminalTab(
          id: tab.id,
          worktreePath: normalizedPath(tab.worktreePath),
          worktreeLabel: tab.worktreeLabel,
          title: tab.title,
          commandDescription: tab.commandDescription,
          kind: tab.kind,
          createdAt: tab.createdAt,
          isSandboxed: tab.isSandboxed,
          writableRoots: tab.writableRoots.map(normalizedPath)
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

  func createReviewTarget(launchContext: ReviewLaunchContext = .standalone) async throws
    -> ReviewTarget
  {
    guard let selectedWorktree else {
      throw GitService.GitError.commandFailed("Select a worktree before starting review.")
    }

    isLaunchingReview = true
    defer { isLaunchingReview = false }
    let worktreePath = normalizedPath(selectedWorktree.path)
    var reviewTarget = try await Task.detached {
      try ArgonCLI.createSession(repoRoot: selectedWorktree.path)
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
    activeFinalizeAction = nil
    dismissMergeBackOptions()
  }

  func beginReviewLaunchFlow() {
    let candidates = eligibleReviewAgentTabs()

    switch candidates.count {
    case 0:
      presentAgentLaunchSheet(reviewAfterLaunch: true)
    case 1:
      pendingReviewAgentTabID = candidates[0].id
    default:
      reviewAgentCandidates = candidates
      isPresentingReviewAgentPicker = true
    }
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
        let prompt = try finalizePrompt(for: finalizeAction)
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

    let target = try await createReviewTarget(launchContext: .coderHandoff)

    do {
      let prompt = try await Task.detached {
        try ArgonCLI.agentPrompt(sessionId: target.sessionId, repoRoot: target.repoRoot)
      }.value

      guard let tab = openAgentTab(options.buildRequest(prompt: prompt)) else {
        throw GitService.GitError.commandFailed("Open a worktree before launching a review agent.")
      }

      stageReviewLaunch(target: target, agentTabID: tab.id)
      shouldLaunchReviewAfterNextAgentTab = false
    } catch {
      try? await Task.detached {
        try ArgonCLI.closeSession(sessionId: target.sessionId, repoRoot: target.repoRoot)
      }.value
      refreshReviewSnapshot(for: target.repoRoot)
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

    let tab = WorkspaceTerminalTab(
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
          writableRoots: [worktree.path]
        )
        : TerminalLaunchConfiguration.shell(currentDirectory: worktree.path),
      isSandboxed: sandboxed,
      writableRoots: sandboxed ? [normalizedPath(worktree.path)] : [],
      isRestorableAfterRelaunch: true
    )

    insertTerminalTab(tab, for: worktreePath)
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
    let launch =
      request.sandboxEnabled
      ? TerminalLaunchConfiguration.sandboxedCommand(
        request.command,
        currentDirectory: worktree.path,
        writableRoots: writableRoots
      )
      : TerminalLaunchConfiguration.command(request.command, currentDirectory: worktree.path)

    let tab = WorkspaceTerminalTab(
      worktreePath: worktreePath,
      worktreeLabel: worktree.branchName ?? repoName,
      title: agentTabTitle(for: request, ordinal: ordinal),
      commandDescription: request.command,
      kind: .agent(profileName: request.displayName, icon: request.icon),
      launch: launch,
      isSandboxed: request.sandboxEnabled,
      writableRoots: writableRoots.map(normalizedPath),
      isRestorableAfterRelaunch: request.isRestorableAfterRelaunch
    )

    insertTerminalTab(tab, for: worktreePath)
    return tab
  }

  func selectTerminalTab(_ tabID: UUID) {
    guard let worktreePath = normalizedSelectedWorktreePath else { return }
    selectedTerminalTabIDsByWorktreePath[worktreePath] = tabID
    requestTerminalFocus(in: worktreePath)
    notifyRestorableStateChanged()
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
      GhosttyTerminalView.releaseTerminal(tabID)
      notifyRestorableStateChanged()
      return
    }
  }

  func handleTerminalExit(_ tabID: UUID, exitBehavior: WorkspaceFinishedTerminalBehavior) {
    guard let tab = terminalTab(for: tabID) else { return }
    tab.isRunning = false

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
        GitService.pullRequestCompareURL(
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
    let commandStatuses = UserShell.loginCommandStatuses(
      persistedTabs.compactMap { persistedTab in
        guard case .agent = persistedTab.kind else { return nil }
        return commandExecutableToken(from: persistedTab.commandDescription)
      }
    )

    var restorableTabs: [PersistedWorkspaceTerminalTab] = []
    var missingAgentCount = 0

    for persistedTab in persistedTabs {
      if case .agent = persistedTab.kind {
        let executable = commandExecutableToken(from: persistedTab.commandDescription)
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

    switch persistedTab.kind {
    case .shell:
      kind = .shell
      launch =
        persistedTab.isSandboxed
        ? TerminalLaunchConfiguration.sandboxedShell(
          currentDirectory: persistedTab.worktreePath,
          writableRoots: persistedTab.writableRoots
        )
        : TerminalLaunchConfiguration.shell(currentDirectory: persistedTab.worktreePath)
    case .agent(let profileName, let icon):
      kind = .agent(profileName: profileName, icon: icon)
      launch =
        persistedTab.isSandboxed
        ? TerminalLaunchConfiguration.sandboxedCommand(
          persistedTab.commandDescription,
          currentDirectory: persistedTab.worktreePath,
          writableRoots: persistedTab.writableRoots
        )
        : TerminalLaunchConfiguration.command(
          persistedTab.commandDescription,
          currentDirectory: persistedTab.worktreePath
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
      isRestorableAfterRelaunch: true
    )
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
    reviewSnapshotsByWorktreePath =
      reviewSnapshotsByWorktreePath
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

    return action.prompt(
      repoRoot: self.target.repoRoot,
      worktreePath: selectedWorktree.path,
      branchName: branchName,
      baseRef: target.baseRef,
      compareURL: selectedPullRequestURL
    )
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
