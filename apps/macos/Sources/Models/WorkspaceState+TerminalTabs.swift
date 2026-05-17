import Foundation

extension WorkspaceState {
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
        guard let openedTab else {
          cancelFinalizeRequest(for: finalizeAction)
          throw GitService.GitError.commandFailed(
            "Open a worktree before launching a finalize agent."
          )
        }
        setPendingFinalizeRequestSourceTab(
          for: finalizeAction,
          worktreePath: openedTab.worktreePath,
          sourceTabID: openedTab.id
        )
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
        try ArgonLib.closeSession(sessionId: target.sessionId, repoRoot: target.repoRoot)
      }.value
      refreshReviewSnapshot(for: target.repoRoot)
      pendingReviewPreparationAfterAgentLaunch = nil
      throw error
    }
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
      worktreeLabel: worktree.displayName,
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

  func confirmSandboxedShellLaunch(
    configuration: SandboxfileWizardConfiguration = .recommended
  ) {
    guard let prompt = pendingShellSandboxfilePrompt else { return }
    let launchCount = max(pendingSandboxedShellLaunchCount, 1)
    pendingShellSandboxfilePrompt = nil
    pendingSandboxedShellLaunchCount = 0

    Task { @MainActor in
      do {
        try await Self.sandboxfileCreator(prompt, configuration)
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
      worktreeLabel: worktree.displayName,
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

  func selectTerminalTab(_ tabID: UUID) {
    guard let worktreePath = normalizedSelectedWorktreePath else { return }
    guard terminalTabsByWorktreePath[worktreePath]?.contains(where: { $0.id == tabID }) == true
    else { return }
    selectedTerminalTabIDsByWorktreePath[worktreePath] = tabID
    clearTerminalAttentionState(tabID)
    requestTerminalFocus(in: worktreePath)
    notifyRestorableStateChanged()
  }

  var canSelectNextTerminalTab: Bool {
    selectedTerminalTabs.count > 1
  }

  var canSelectPreviousTerminalTab: Bool {
    selectedTerminalTabs.count > 1
  }

  @discardableResult
  func selectNextTerminalTab() -> Bool {
    selectTerminalTab(offset: 1)
  }

  @discardableResult
  func selectPreviousTerminalTab() -> Bool {
    selectTerminalTab(offset: -1)
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

  func scheduleAgentActivityIdle(_ tabID: UUID) {
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
      self.notifyRestorableStateChanged()
    }
  }

  @discardableResult
  func clearTerminalAttentionState(_ tabID: UUID) -> Bool {
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

  func closeTerminalTab(
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
  func reconnectPersistentTerminalSessionIfRunning(
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

  func insertTerminalTab(_ tab: WorkspaceTerminalTab, for worktreePath: String) {
    terminalTabsByWorktreePath[worktreePath, default: []].append(tab)
    selectedTerminalTabIDsByWorktreePath[worktreePath] = tab.id
    requestTerminalFocus(in: worktreePath)
    notifyRestorableStateChanged()
  }

  @discardableResult
  private func selectTerminalTab(offset: Int) -> Bool {
    let tabs = selectedTerminalTabs
    guard tabs.count > 1 else { return false }

    let selectedID = selectedTerminalTab?.id
    let currentIndex = tabs.firstIndex { $0.id == selectedID } ?? 0
    let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
    selectTerminalTab(tabs[nextIndex].id)
    return true
  }

  func configureUITestWebsiteDemo(useLiveAgentCommands: Bool) {
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
  func insertUITestWebsiteDemoTab(
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
      worktreeLabel: worktree.displayName,
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

  func writeUITestWebsiteDemoNetworkLog(for tabID: UUID) {
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

  static func websiteDemoAgentProcessSpec(
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

  static func installedExecutablePath(
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

  static func websiteDemoShellScript(lines: [String], sleepSeconds: Int) -> String {
    let quotedLines = lines.map { line in
      "'\(line.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
    return "printf '%s\\n' \(quotedLines.joined(separator: " ")); sleep \(sleepSeconds)"
  }

  func nextOrdinal(
    in worktreePath: String,
    where predicate: (WorkspaceTerminalTab) -> Bool
  ) -> Int {
    (terminalTabsByWorktreePath[worktreePath] ?? []).filter(predicate).count + 1
  }

  func agentTabTitle(for request: WorkspaceAgentLaunchRequest, ordinal: Int) -> String {
    guard ordinal > 1 else { return request.displayName }
    if request.useHashedDuplicateSuffix {
      return "\(request.displayName) #\(ordinal)"
    }
    return "\(request.displayName) \(ordinal)"
  }

  func requiredDirectWritableRoots(for _: WorktreeFinalizeAction) -> [String] {
    guard let selectedWorktree else { return [target.repoRoot] }
    return [selectedWorktree.path]
  }

  func uniqueWritableRoots(
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
}
