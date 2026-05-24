import Foundation

extension WorkspaceState {
  @discardableResult
  func beginReviewLaunchFlow() -> WorkspaceReviewLaunchDecision? {
    guard let selectedWorktree else { return nil }
    let worktreePath = normalizedPath(selectedWorktree.path)
    materializePendingRunningAgentTabs(for: worktreePath)
    let candidates = eligibleReviewAgentTabs()
    reviewAgentCandidates = candidates
    let preparation = WorkspaceReviewPreparation(
      worktreePath: worktreePath,
      draft: reviewSummaryDraftsByWorktreePath[worktreePath] ?? .empty,
      selectedAgentTabID: candidates.count == 1 ? candidates[0].id : nil
    )
    pendingReviewPreparation = preparation

    switch candidates.count {
    case 0:
      isPresentingReviewPreparationSheet = false
      return .launchAgent
    case 1:
      isPresentingReviewPreparationSheet = false
      return .useExistingAgent(candidates[0].id, preparation)
    default:
      isPresentingReviewPreparationSheet = true
      return .chooseExistingAgent
    }
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
    reviewAgentCandidates = []
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
    guard canMergeBackSelectedWorktree else { return }
    beginFinalizeFlow(.mergeBackToBase)
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
    guard canOpenPullRequestForSelectedWorktree, let url = selectedPullRequestBrowserURL else {
      return
    }
    if !Self.pullRequestURLOpener(url) {
      errorMessage = "Could not open pull request URL."
    }
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

  func beginAgentFinalizeFlow(_ action: WorktreeFinalizeAction) {
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
  func beginLocalMergeBackIfAvailable(
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

  func activateStagedReviewLaunch() {
    guard let stagedReviewLaunch else { return }
    preparedReviewTargetsByAgentTabID[stagedReviewLaunch.agentTabID] = stagedReviewLaunch.target
    pendingReviewAgentTabID = stagedReviewLaunch.agentTabID
    self.stagedReviewLaunch = nil
  }

  func consumePreparedReviewTarget(for agentTabID: UUID) -> ReviewTarget? {
    preparedReviewTargetsByAgentTabID.removeValue(forKey: agentTabID)
  }

  func eligibleReviewAgentTabs() -> [WorkspaceTerminalTab] {
    selectedTerminalTabs.filter { tab in
      guard tab.isRunning else { return false }
      if case .agent = tab.kind {
        return true
      }
      return false
    }
  }

  func eligibleFinalizeAgentTabs(for action: WorktreeFinalizeAction)
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

  func finalizeSandboxBrokerInstructions(
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

  func setPendingFinalizeRequestSourceTab(
    for action: WorktreeFinalizeAction,
    worktreePath: String,
    sourceTabID: UUID
  ) {
    let normalizedWorktreePath = normalizedPath(worktreePath)
    guard
      let entry = activeAgentControlRequestsByID.first(where: { entry in
        let pending = entry.value
        return pending.worktreePath == normalizedWorktreePath
          && pending.request.action == .finalize(action)
      })
    else { return }

    activeAgentControlRequestsByID[entry.key] = PendingWorkspaceAgentControlRequest(
      request: entry.value.request,
      worktreePath: entry.value.worktreePath,
      responseFilePath: entry.value.responseFilePath,
      sourceTabID: sourceTabID
    )
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
    guard let target = selectedFinalizeTarget(), target.mode == .branch else {
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
      commitBeforeLanding: action.isMergeBackAction
        && (selectedBranchTopology?.aheadCount ?? 0) == 0
    )
  }

  func selectedFinalizeTarget() -> ResolvedTarget? {
    if let selectedReviewTarget, selectedReviewTarget.mode == .branch {
      return selectedReviewTarget
    }
    guard let selectedWorktree else { return nil }
    return GitService.resolveWorkspaceTarget(repoRoot: selectedWorktree.path, diffMode: .allChanges)
  }

  func beginAgentControlRequest(
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

  func cancelConflictingAgentControlRequests(
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

  func cancelAgentControlRequest(_ requestID: UUID) {
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

  func consumeAgentControlResponse(
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

  func handleReviewSummaryResponse(
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

  func handleFinalizeResponse(
    action: WorktreeFinalizeAction,
    status: WorkspaceAgentControlStatus,
    message: String,
    pullRequestURL: String?,
    followUp: String?,
    pendingRequest: PendingWorkspaceAgentControlRequest
  ) {
    switch status {
    case .success:
      if action == .rebaseOntoBase {
        if let sourceTabID = pendingRequest.sourceTabID {
          markAgentWaitingForHuman(sourceTabID)
          markTerminalNeedsAttention(sourceTabID)
        }
      } else if action.isMergeBackAction {
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

  nonisolated static func waitForAgentControlResponse(
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

  nonisolated static func agentControlDirectoryURL(for worktreePath: String) -> URL {
    let normalizedWorktreePath = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-agent-control", isDirectory: true)
      .appendingPathComponent("w-\(pathHash(normalizedWorktreePath))", isDirectory: true)
  }

  nonisolated static func pathHash(_ path: String) -> String {
    String(format: "%016llx", fnv1a64(Array(path.utf8)))
  }

  nonisolated static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return hash
  }

  func mergeBackOptions(for topology: BranchTopology) -> [WorktreeFinalizeAction] {
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

  func persistReviewSummaryDraft(
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

  func stageReviewLaunch(target: ReviewTarget, agentTabID: UUID) {
    stagedReviewLaunch = StagedReviewLaunch(target: target, agentTabID: agentTabID)
  }
}

struct StagedReviewLaunch {
  let target: ReviewTarget
  let agentTabID: UUID
}
