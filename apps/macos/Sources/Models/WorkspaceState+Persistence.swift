import Foundation

extension WorkspaceState {
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
          Self.pendingTabShouldRestoreInBackground(normalizedTab)
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

  func closeStoppedAgentTabs(matching session: WorkspaceRestorableAgentSession) {
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

  nonisolated static func restorePersistedTabs(
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

  nonisolated static func restoreRunningBackgroundAgentTabs(
    _ persistedTabs: [PersistedWorkspaceTerminalTab]
  ) -> RestoredPersistedTabs {
    let hydratedTabs = hydratedPersistedAgentResumeMetadata(for: persistedTabs)
    return RestoredPersistedTabs(
      persistedTabs: hydratedTabs.filter(Self.pendingTabRepresentsRunningBackgroundAgent),
      missingAgentCount: 0
    )
  }

  nonisolated static func restoreBackgroundAgentTabs(
    _ persistedTabs: [PersistedWorkspaceTerminalTab]
  ) -> RestoredPersistedTabs {
    restorePersistedTabs(persistedTabs.filter(Self.pendingTabShouldRestoreInBackground))
  }

  static func restoredTerminalTab(
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

  static func terminalSessionForRestore(_ tab: PersistedWorkspaceTerminalTab)
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

  static func replacementTerminalSessionForRestore(_ tab: PersistedWorkspaceTerminalTab)
    -> TerminalSessionReference?
  {
    guard AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence else {
      return nil
    }
    guard case .agent = tab.kind else { return nil }
    guard tab.keepsRunningAfterQuit || tab.terminalSession != nil else { return nil }
    return Self.terminalSessionReferenceProvider(tab.id, tab.worktreePath)
  }

  static func restoredKeepsRunningAfterQuit(
    persistedTab: PersistedWorkspaceTerminalTab,
    kind: WorkspaceTerminalKind,
    terminalSession: TerminalSessionReference?
  ) -> Bool {
    guard case .agent = kind else {
      return persistedTab.keepsRunningAfterQuit
    }
    return persistedTab.keepsRunningAfterQuit || terminalSession != nil
  }

  nonisolated static func hydratedPersistedAgentResumeMetadata(
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

  nonisolated static func agentFamilyIDForResumeHydration(
    _ tab: PersistedWorkspaceTerminalTab
  ) -> AgentFamilyID? {
    tab.agentFamilyID ?? AgentHarnesses.familyID(matchingCommand: tab.commandDescription)
  }

  nonisolated static func yoloFlag(for tab: PersistedWorkspaceTerminalTab) -> String {
    guard case .agent = tab.kind else { return "" }
    guard
      let familyID = tab.agentFamilyID
        ?? AgentHarnesses.familyID(
          matchingCommand: tab.baseCommandDescription
        )
    else { return "" }
    return familyID.defaultProfile.yoloFlag
  }

  nonisolated static func resumeSessionsByHydrationGroup(
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

  static func persistedTerminalTab(from tab: WorkspaceTerminalTab)
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

  nonisolated static func persistedTabByResolvingResumeTemplate(
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

  func refreshPendingAgentActivitySummaries() {
    let worktreePaths = Set(
      Array(pendingRestorableTabsByWorktreePath.keys)
        + Array(pendingAgentActivitySummariesByWorktreePath.keys)
    )
    for worktreePath in worktreePaths {
      refreshPendingAgentActivitySummary(for: worktreePath)
    }
  }

  func refreshPendingAgentActivitySummary(for worktreePath: String) {
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

  func pendingRunningBackgroundAgentCount() -> Int {
    pendingRestorableTabsByWorktreePath.values.reduce(0) { count, tabs in
      count + tabs.filter(Self.pendingTabContributesSidebarAgentActivity).count
    }
  }

  nonisolated static func pendingAgentActivitySummary(
    for tabs: [PersistedWorkspaceTerminalTab]
  ) -> WorktreeAgentActivitySummary {
    tabs.reduce(into: .empty) { summary, tab in
      guard pendingTabContributesSidebarAgentActivity(tab) else { return }
      let isWaitingForHuman = tab.hasAttention || tab.agentActivityState == .waitingForHuman

      summary = WorktreeAgentActivitySummary(
        waitingForHumanCount: summary.waitingForHumanCount + (isWaitingForHuman ? 1 : 0),
        thinkingCount: summary.thinkingCount
          + (tab.agentActivityState == .thinking ? 1 : 0),
        runningAgentCount: summary.runningAgentCount + 1
      )
    }
  }

  nonisolated static func pendingTabContributesSidebarAgentActivity(
    _ tab: PersistedWorkspaceTerminalTab
  ) -> Bool {
    pendingTabRepresentsRunningBackgroundAgent(tab)
      || pendingTabShouldRestoreInBackground(tab)
  }

  nonisolated static func pendingTabShouldRestoreInBackground(
    _ tab: PersistedWorkspaceTerminalTab
  ) -> Bool {
    guard case .agent = tab.kind else { return false }
    guard AgentTerminalPersistenceExperimentSettings.canUseTerminalSessionPersistence else {
      return false
    }
    return tab.keepsRunningAfterQuit || pendingTabRepresentsRunningBackgroundAgent(tab)
  }

  nonisolated static func pendingTabRepresentsRunningBackgroundAgent(
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

  static func restoreMetadataByProfileIDOrName(savedProfiles: [SavedAgentProfile])
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

  static func agentProfilesByID(savedProfiles: [SavedAgentProfile])
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

  static func sessionSpecificResumeArgumentTemplate(
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

  static func agentCommand(
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

  static func agentSessionKey(
    familyID: AgentFamilyID,
    sessionID: String
  ) -> String {
    "\(familyID.rawValue):\(sessionID)"
  }

  nonisolated static func formattedRestoreFailureMessage(
    missingAgentCount: Int,
    worktreeLabel: String
  ) -> String {
    let noun = missingAgentCount == 1 ? "agent tab" : "agent tabs"
    let availability = missingAgentCount == 1 ? "its command is" : "their commands are"
    return
      "\(missingAgentCount) \(noun) couldn’t be restored for \(worktreeLabel) because \(availability) no longer available."
  }

  func startPendingTabRestoreIfNeeded(for worktreePath: String) {
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

  func startRunningBackgroundAgentRestores(
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

  func startPendingRunningBackgroundAgentRestoreIfNeeded(for worktreePath: String) {
    let normalizedPath = normalizedPath(worktreePath)
    guard pendingTabRestoreTasksByWorktreePath[normalizedPath] == nil,
      let persistedTabs = pendingRestorableTabsByWorktreePath[normalizedPath],
      !persistedTabs.isEmpty
    else {
      return
    }

    let backgroundAgentTabs = persistedTabs.filter(Self.pendingTabShouldRestoreInBackground)
    guard !backgroundAgentTabs.isEmpty else {
      refreshPendingAgentActivitySummary(for: normalizedPath)
      return
    }

    refreshPendingAgentActivitySummary(for: normalizedPath)

    startPendingTabRestoreTask(
      for: normalizedPath,
      persistedTabs: backgroundAgentTabs,
      removeRestoredTabsFromPending: true
    )
  }

  func startPendingTabRestoreTask(
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
          return Self.restoreBackgroundAgentTabs(persistedTabs)
        }
        return Self.restorePersistedTabs(persistedTabs)
      }.value

      guard let self, !Task.isCancelled else { return }
      self.pendingTabRestoreTasksByWorktreePath.removeValue(forKey: normalizedPath)
      let attemptedTabIDs =
        removeRestoredTabsFromPending ? Set(persistedTabs.map(\.id)) : []
      self.applyRestoredPersistedTabs(
        restored,
        for: normalizedPath,
        removeRestoredTabsFromPending: removeRestoredTabsFromPending,
        attemptedTabIDs: attemptedTabIDs
      )
    }
  }

  @discardableResult
  func materializePendingRunningAgentTabs(for worktreePath: String) -> Bool {
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

  func applyRestoredPersistedTabs(
    _ restored: RestoredPersistedTabs,
    for normalizedPath: String,
    removeRestoredTabsFromPending: Bool,
    attemptedTabIDs: Set<UUID> = []
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
      let removableTabIDs = attemptedTabIDs.isEmpty ? restoredTabIDs : attemptedTabIDs
      var pendingTabs = pendingRestorableTabsByWorktreePath[normalizedPath] ?? []
      pendingTabs.removeAll { removableTabIDs.contains($0.id) }
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

  func restoredWorktreeLabel(for worktreePath: String) -> String {
    worktrees.first(where: { normalizedPath($0.path) == worktreePath })?.displayName
      ?? URL(fileURLWithPath: worktreePath).lastPathComponent
  }

  func terminalTab(for tabID: UUID) -> WorkspaceTerminalTab? {
    terminalTabsByWorktreePath.values
      .joined()
      .first { $0.id == tabID }
  }

  func persistAgentSessionRestoreMetadataIfPossible(for tab: WorkspaceTerminalTab) {
    guard let sessionID = tab.resumeSessionID ?? hydrateAgentResumeSessionID(for: tab) else {
      return
    }

    tab.resumeSessionID = sessionID
    recordAgentSessionRestoreMetadata(for: tab, sessionID: sessionID)
  }

  func preserveRestorableAgentTabForLater(_ tab: WorkspaceTerminalTab) {
    guard let persistedTab = stoppedRestorableAgentTab(from: tab) else { return }
    let worktreePath = normalizedPath(tab.worktreePath)
    var pendingTabs = pendingRestorableTabsByWorktreePath[worktreePath] ?? []
    pendingTabs.removeAll { $0.id == persistedTab.id }
    pendingTabs.append(persistedTab)
    pendingRestorableTabsByWorktreePath[worktreePath] = pendingTabs
    refreshPendingAgentActivitySummary(for: worktreePath)
  }

  func stoppedRestorableAgentTab(
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

  func hydrateAgentResumeSessionID(for tab: WorkspaceTerminalTab) -> String? {
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

  func recordAgentSessionRestoreMetadata(
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
}

struct RestoredPersistedTabs: Sendable {
  let persistedTabs: [PersistedWorkspaceTerminalTab]
  let missingAgentCount: Int
}

struct AgentResumeHydrationGroup: Hashable, Sendable {
  let familyID: AgentFamilyID
  let worktreePath: String
}

struct AgentRestoreProfileMetadata: Sendable {
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
