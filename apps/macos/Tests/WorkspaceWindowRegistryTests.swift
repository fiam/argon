import AppKit
import Foundation
import Testing

@testable import Argon

@Suite("WorkspaceWindowRegistry")
struct WorkspaceWindowRegistryTests {

  @Test("opening the same repo root while a window is pending does not request a duplicate window")
  @MainActor
  func openingPendingRepoRootDoesNotRequestDuplicateWindow() {
    let registry = WorkspaceWindowRegistry()
    let initialTarget = makeTarget(selectedWorktreePath: "/tmp/repo")
    let updatedTarget = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-a")
    var openedTargets: [WorkspaceTarget] = []

    registry.open(target: initialTarget) { target in
      openedTargets.append(target)
    }
    registry.open(target: updatedTarget) { target in
      openedTargets.append(target)
    }

    #expect(openedTargets == [initialTarget])

    let state = WorkspaceState(target: initialTarget)
    state.isLoading = true
    let window = NSWindow()

    registry.register(window: window, workspaceState: state, repoRoot: initialTarget.repoRoot)

    #expect(state.selectedWorktreePath == updatedTarget.selectedWorktreePath)
    #expect(state.launchWarningMessage == nil)
  }

  @Test("a timed out pending workspace open can be retried")
  @MainActor
  func timedOutPendingWorkspaceOpenCanBeRetried() async {
    let registry = WorkspaceWindowRegistry(openRequestTimeout: .milliseconds(10))
    let target = makeTarget(selectedWorktreePath: "/tmp/repo")
    var openedTargets: [WorkspaceTarget] = []

    registry.open(target: target) { openedTarget in
      openedTargets.append(openedTarget)
    }
    registry.open(target: target) { openedTarget in
      openedTargets.append(openedTarget)
    }

    #expect(openedTargets == [target])

    try? await Task.sleep(for: .milliseconds(30))

    registry.open(target: target) { openedTarget in
      openedTargets.append(openedTarget)
    }

    #expect(openedTargets == [target, target])
  }

  @Test(
    "opening an already opened repo root focuses the existing workspace instead of opening a new one"
  )
  @MainActor
  func openingExistingRepoRootReusesWindow() {
    let registry = WorkspaceWindowRegistry()
    let initialTarget = makeTarget(selectedWorktreePath: "/tmp/repo")
    let updatedTarget = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = WorkspaceState(target: initialTarget)
    state.isLoading = true
    let window = NSWindow()
    var openCount = 0

    registry.register(window: window, workspaceState: state, repoRoot: initialTarget.repoRoot)
    registry.open(target: updatedTarget) { _ in
      openCount += 1
    }

    #expect(openCount == 0)
    #expect(state.selectedWorktreePath == updatedTarget.selectedWorktreePath)
    #expect(state.launchWarningMessage == nil)
  }

  @Test("reopening a closed workspace window reuses the retained workspace state")
  @MainActor
  func reopeningClosedWorkspaceWindowReusesRetainedWorkspaceState() {
    let registry = WorkspaceWindowRegistry()
    let initialTarget = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-a")
    let state = registry.workspaceState(for: initialTarget)
    let window = NSWindow()
    var openedTargets: [WorkspaceTarget] = []

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    registry.register(window: window, workspaceState: state, repoRoot: initialTarget.repoRoot)
    registry.unregister(window: window, repoRoot: initialTarget.repoRoot)

    let reopenedState = registry.workspaceState(for: initialTarget)
    registry.open(target: initialTarget) { target in
      openedTargets.append(target)
    }

    #expect(reopenedState === state)
    #expect(openedTargets.count == 1)
    #expect(openedTargets[0].selectedWorktreePath == state.selectedWorktreePath)
  }

  @Test("focusTerminal brings a workspace tab to the front")
  @MainActor
  func focusTerminalBringsWorkspaceTabToFront() {
    let registry = WorkspaceWindowRegistry()
    let target = makeTarget(selectedWorktreePath: "/tmp/repo")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()

    state.worktrees = [
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      ),
      DiscoveredWorktree(
        path: "/tmp/repo-worktrees/feature-b",
        branchName: "feature/b",
        headSHA: "def456",
        isBaseWorktree: false,
        isDetached: false
      ),
    ]

    let featureTab = makeShellTab(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      title: "Shell 1",
      sandboxed: true
    )
    featureTab.hasAttention = true
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [featureTab]

    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)

    let focused = registry.focusTerminal(
      repoRoot: target.repoRoot,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      tabID: featureTab.id
    )

    #expect(focused == true)
    #expect(state.selectedWorktreePath == "/tmp/repo-worktrees/feature-b")
    #expect(state.selectedTerminalTab?.id == featureTab.id)
    #expect(featureTab.hasAttention == false)
  }

  @Test("notification context shows project and workspace only when ambiguous")
  @MainActor
  func notificationContextShowsProjectAndWorkspaceOnlyWhenAmbiguous() {
    let registry = WorkspaceWindowRegistry()
    let target = makeTarget(selectedWorktreePath: "/tmp/repo")
    let state = registry.workspaceState(for: target)
    state.worktrees = [
      makeWorktree(path: "/tmp/repo", branchName: "main", isBaseWorktree: true)
    ]

    registry.register(window: NSWindow(), workspaceState: state, repoRoot: target.repoRoot)

    #expect(
      registry.notificationContext(for: target.repoRoot)
        == WorkspaceTerminalNotificationContext(showsProject: false, showsWorkspace: false)
    )

    state.worktrees.append(
      makeWorktree(path: "/tmp/repo-worktrees/feature-b", branchName: "feature/b")
    )

    #expect(
      registry.notificationContext(for: target.repoRoot)
        == WorkspaceTerminalNotificationContext(showsProject: false, showsWorkspace: true)
    )

    let secondTarget = WorkspaceTarget(
      repoRoot: "/tmp/other-repo",
      repoCommonDir: "/tmp/other-repo/.git",
      selectedWorktreePath: "/tmp/other-repo"
    )
    let secondState = registry.workspaceState(for: secondTarget)
    secondState.worktrees = [
      makeWorktree(path: "/tmp/other-repo", branchName: "main", isBaseWorktree: true)
    ]
    registry.register(
      window: NSWindow(),
      workspaceState: secondState,
      repoRoot: secondTarget.repoRoot
    )

    #expect(
      registry.notificationContext(for: target.repoRoot)
        == WorkspaceTerminalNotificationContext(showsProject: true, showsWorkspace: true)
    )
    #expect(
      registry.notificationContext(for: secondTarget.repoRoot)
        == WorkspaceTerminalNotificationContext(showsProject: true, showsWorkspace: false)
    )
  }

  @Test("cold restore reopens the selected worktree and restores its tabs lazily")
  @MainActor
  func coldRestoreReopensTheSelectedWorktreeAndRestorableTerminalTabs() async {
    let suiteName = "WorkspaceWindowRegistryTests.coldRestore"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    do {
      let registry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
      let target = makeTarget(selectedWorktreePath: "/tmp/repo")
      let state = registry.workspaceState(for: target)
      let window = NSWindow()

      state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
      state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [
        makeShellTab(
          id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
          worktreePath: "/tmp/repo-worktrees/feature-b",
          title: "Shell 1",
          sandboxed: true
        ),
        makeShellTab(
          id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
          worktreePath: "/tmp/repo-worktrees/feature-b",
          title: "Privileged Shell 1",
          sandboxed: false
        ),
        makeAgentTab(
          id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
          worktreePath: "/tmp/repo-worktrees/feature-b",
          title: "Codex",
          command: "/bin/sh -lc 'printf restored\\n'",
          sandboxed: true
        ),
        makeAgentTab(
          id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
          worktreePath: "/tmp/repo-worktrees/feature-b",
          title: "Review Handoff",
          command: "codex --yolo 'handoff prompt'",
          sandboxed: true,
          isRestorableAfterRelaunch: false
        ),
      ]
      state.selectedTerminalTabIDsByWorktreePath["/tmp/repo-worktrees/feature-b"] =
        UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

      registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)
    }

    let restoredRegistry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    let target = makeTarget(selectedWorktreePath: "/tmp/repo")
    var openedTargets: [WorkspaceTarget] = []

    let restoredCount = restoredRegistry.restorePersistedWorkspacesIfNeeded { restoredTarget in
      openedTargets.append(restoredTarget)
    }
    let restoredState = restoredRegistry.workspaceState(for: target)

    #expect(restoredCount == 1)
    #expect(
      openedTargets == [
        WorkspaceTarget(
          repoRoot: "/tmp/repo",
          repoCommonDir: "/tmp/repo/.git",
          selectedWorktreePath: "/tmp/repo-worktrees/feature-b"
        )
      ])
    #expect(restoredState.selectedWorktreePath == "/tmp/repo-worktrees/feature-b")
    #expect(restoredState.allTerminalTabs.isEmpty)

    restoredState.prepareSelectionLoading(for: "/tmp/repo-worktrees/feature-b")
    #expect(
      await waitUntil {
        restoredState.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] != nil
      }
    )

    let restoredTabs = restoredState.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"]
    #expect(
      restoredTabs?.map { $0.title } == [
        "Shell 1",
        "Privileged Shell 1",
        "Codex",
      ])
    #expect(
      restoredTabs?.first(where: { $0.title == "Codex" })?.commandDescription
        == "/bin/sh -lc 'printf restored\\n'")
    #expect(
      restoredTabs?.first(where: { $0.title == "Codex" })?.isSandboxed == true
    )
    #expect(
      restoredState.selectedTerminalTabIDsByWorktreePath["/tmp/repo-worktrees/feature-b"]
        == UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    )
  }

  @Test("system-restored workspace scenes seed state from persisted snapshots")
  @MainActor
  func systemRestoredWorkspaceScenesSeedStateFromPersistedSnapshots() {
    let suiteName = "WorkspaceWindowRegistryTests.systemRestoredScene"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    do {
      let registry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
      let target = makeTarget(selectedWorktreePath: "/tmp/repo")
      let state = registry.workspaceState(for: target)
      let window = NSWindow()

      state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
      state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [
        makeAgentTab(
          id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!,
          worktreePath: "/tmp/repo-worktrees/feature-b",
          title: "Codex",
          command: "/bin/sh -lc 'printf restored\\n'",
          sandboxed: true
        )
      ]
      state.selectedTerminalTabIDsByWorktreePath["/tmp/repo-worktrees/feature-b"] =
        UUID(uuidString: "12121212-1212-1212-1212-121212121212")!

      registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)
    }

    let restoredRegistry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    let restoredState = restoredRegistry.workspaceState(
      for: makeTarget(selectedWorktreePath: "/tmp/repo"))

    #expect(restoredState.selectedWorktreePath == "/tmp/repo-worktrees/feature-b")
    #expect(restoredState.allTerminalTabs.isEmpty)

    var openedTargets: [WorkspaceTarget] = []
    #expect(
      restoredRegistry.restorePersistedWorkspacesIfNeeded { target in
        openedTargets.append(target)
      } == 0
    )
    #expect(openedTargets.isEmpty)
  }

  @Test("persisted snapshots still apply when a system-restored scene creates state first")
  @MainActor
  func persistedSnapshotsApplyWhenSystemRestoredSceneCreatesStateFirst() async {
    let suiteName = "WorkspaceWindowRegistryTests.sceneBeforeWelcomeRestore"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    do {
      let registry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
      let target = makeTarget(selectedWorktreePath: "/tmp/repo")
      let state = registry.workspaceState(for: target)
      let window = NSWindow()

      state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
      state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [
        makeAgentTab(
          id: UUID(uuidString: "45454545-4545-4545-4545-454545454545")!,
          worktreePath: "/tmp/repo-worktrees/feature-b",
          title: "Codex",
          command: "/bin/sh -lc 'printf restored\\n'",
          sandboxed: true
        )
      ]
      state.selectedTerminalTabIDsByWorktreePath["/tmp/repo-worktrees/feature-b"] =
        UUID(uuidString: "45454545-4545-4545-4545-454545454545")!

      registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)
    }

    let restoredRegistry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    let systemRestoredTarget = makeTarget(selectedWorktreePath: "/tmp/repo")
    let stateCreatedByScene = restoredRegistry.workspaceState(for: systemRestoredTarget)

    #expect(stateCreatedByScene.selectedWorktreePath == "/tmp/repo-worktrees/feature-b")
    #expect(stateCreatedByScene.selectedTerminalTab == nil)

    stateCreatedByScene.prepareSelectionLoading(for: "/tmp/repo-worktrees/feature-b")
    #expect(await waitUntil { stateCreatedByScene.selectedTerminalTab != nil })

    #expect(stateCreatedByScene.selectedTerminalTab?.title == "Codex")
    #expect(
      stateCreatedByScene.selectedTerminalTab?.commandDescription
        == "/bin/sh -lc 'printf restored\\n'"
    )

    var openedTargets: [WorkspaceTarget] = []
    #expect(
      restoredRegistry.restorePersistedWorkspacesIfNeeded { target in
        openedTargets.append(target)
      } == 0
    )
    #expect(openedTargets.isEmpty)
  }

  @Test("late snapshots do not overwrite a live workspace state")
  @MainActor
  func lateSnapshotsDoNotOverwriteLiveWorkspaceState() {
    let suiteName = "WorkspaceWindowRegistryTests.lateSnapshot"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let registry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    let target = makeTarget(selectedWorktreePath: "/tmp/repo")
    let state = registry.workspaceState(for: target)
    state.worktrees = [
      DiscoveredWorktree(
        path: "/tmp/repo",
        branchName: "main",
        headSHA: "abc123",
        isBaseWorktree: true,
        isDetached: false
      ),
      DiscoveredWorktree(
        path: "/tmp/repo-worktrees/feature-b",
        branchName: "feature/window",
        headSHA: "def456",
        isBaseWorktree: false,
        isDetached: false
      ),
    ]
    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.openShellTab(sandboxed: false)

    let staleSnapshot = PersistedWorkspaceWindowSnapshot(
      target: WorkspaceTarget(
        repoRoot: "/tmp/repo",
        repoCommonDir: "/tmp/repo/.git",
        selectedWorktreePath: "/tmp/repo"
      ),
      terminalTabsByWorktreePath: [
        "/tmp/repo": [
          PersistedWorkspaceTerminalTab(
            id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            worktreePath: "/tmp/repo",
            worktreeLabel: "main",
            title: "Shell 1",
            commandDescription: "Sandboxed /bin/zsh",
            kind: .shell,
            createdAt: Date(timeIntervalSince1970: 1),
            isSandboxed: true,
            writableRoots: ["/tmp/repo"]
          )
        ]
      ],
      selectedTerminalTabIDsByWorktreePath: [
        "/tmp/repo": UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
      ]
    )

    let data = try! JSONEncoder().encode([staleSnapshot])
    defaults.set(data, forKey: suiteName)

    let resolvedState = registry.workspaceState(for: target)

    #expect(resolvedState === state)
    #expect(resolvedState.selectedWorktreePath == "/tmp/repo-worktrees/feature-b")
    #expect(resolvedState.selectedTerminalTabs.map(\.title) == ["Privileged Shell 1"])
  }

  @Test("restore only runs once per registry instance")
  @MainActor
  func restoreOnlyRunsOncePerRegistryInstance() {
    let suiteName = "WorkspaceWindowRegistryTests.restoreOnce"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let seededRegistry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-a")
    seededRegistry.register(
      window: NSWindow(),
      workspaceState: seededRegistry.workspaceState(for: target),
      repoRoot: target.repoRoot
    )

    let restoredRegistry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    var openCount = 0

    #expect(
      restoredRegistry.restorePersistedWorkspacesIfNeeded { _ in
        openCount += 1
      } == 1
    )
    #expect(
      restoredRegistry.restorePersistedWorkspacesIfNeeded { _ in
        openCount += 1
      } == 0
    )
    #expect(openCount == 1)
  }

  @Test("closing a workspace window without quitting does not leave a cold-restore snapshot")
  @MainActor
  func closingAWorkspaceWindowWithoutQuittingDoesNotLeaveAColdRestoreSnapshot() async {
    let suiteName = "WorkspaceWindowRegistryTests.closeWithoutQuit"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let registry = WorkspaceWindowRegistry(
      userDefaults: defaults,
      storageKey: suiteName,
      unregisterPersistenceDelay: .milliseconds(10)
    )
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-a")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [
      makeShellTab(
        id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
        worktreePath: "/tmp/repo-worktrees/feature-b",
        title: "Shell 1",
        sandboxed: true
      )
    ]

    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)
    registry.unregister(window: window, repoRoot: target.repoRoot)
    try? await Task.sleep(for: .milliseconds(30))

    let restoredRegistry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    var openedTargets: [WorkspaceTarget] = []

    #expect(
      restoredRegistry.restorePersistedWorkspacesIfNeeded { target in
        openedTargets.append(target)
      } == 0
    )
    #expect(openedTargets.isEmpty)
  }

  @Test("workspace window close prompts for thinking agents")
  @MainActor
  func workspaceWindowClosePromptsForThinkingAgents() {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    var promptedSummaries: [WorkspaceQuitAgentSummary] = []
    let registry = WorkspaceWindowRegistry { summary, _ in
      promptedSummaries.append(summary)
      return .cancel
    }
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()
    let session = TerminalSessionReference(backendID: "test", sessionID: "window-close")
    let tab = makeAgentTab(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      title: "Codex",
      command: "codex --yolo",
      sandboxed: true,
      terminalSession: session,
      keepsRunningAfterQuit: true
    )
    tab.agentActivityState = .thinking

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [tab]

    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)

    #expect(window.delegate?.windowShouldClose?(window) == false)
    #expect(
      promptedSummaries
        == [WorkspaceQuitAgentSummary(warningCount: 1, keepRunningCount: 1, thinkingCount: 1)]
    )
    #expect(tab.terminalSession == session)
  }

  @Test("workspace window close does not prompt for idle persistent agents")
  @MainActor
  func workspaceWindowCloseDoesNotPromptForIdlePersistentAgents() {
    var didPrompt = false
    let registry = WorkspaceWindowRegistry { _, _ in
      didPrompt = true
      return .cancel
    }
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()
    let session = TerminalSessionReference(backendID: "test", sessionID: "window-close")
    let tab = makeAgentTab(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555556")!,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      title: "Codex",
      command: "codex --yolo",
      sandboxed: true,
      terminalSession: session,
      keepsRunningAfterQuit: true
    )

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [tab]

    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)

    #expect(window.delegate?.windowShouldClose?(window) == true)
    #expect(didPrompt == false)
    #expect(tab.terminalSession == session)
  }

  @Test("workspace window close can stop thinking agents")
  @MainActor
  func workspaceWindowCloseCanStopThinkingAgents() throws {
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    defer {
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
    }

    let registry = WorkspaceWindowRegistry { _, _ in .closeAndStopAgents }
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()
    let session = TerminalSessionReference(backendID: "test", sessionID: "window-stop")
    let tab = makeAgentTab(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555557")!,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      title: "Codex",
      command: "codex --yolo",
      sandboxed: true,
      agentFamilyID: .codex,
      resumeArgumentTemplate: "resume {{session_id}}",
      resumeSessionID: "55555555-5555-5555-5555-555555555555",
      resumeCommandDescription: "codex --yolo resume '55555555-5555-5555-5555-555555555555'",
      terminalSession: session,
      keepsRunningAfterQuit: true
    )
    tab.agentActivityState = .thinking

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [tab]

    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)

    #expect(window.delegate?.windowShouldClose?(window) == true)
    #expect(stoppedSessions.sessions == [session])
    #expect(state.allTerminalTabs.contains { $0.id == tab.id } == false)

    let snapshot = state.persistedWindowSnapshot
    let persistedTabs = try #require(
      snapshot.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"])
    let persistedTab = try #require(persistedTabs.first { $0.id == tab.id })
    #expect(persistedTab.terminalSession == nil)
    #expect(persistedTab.resumeSessionID == "55555555-5555-5555-5555-555555555555")
  }

  @Test("workspace window close keeps persistent terminal sessions")
  @MainActor
  func workspaceWindowCloseKeepsPersistentTerminalSessions() {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    defer {
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
    }

    let registry = WorkspaceWindowRegistry()
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()
    let session = TerminalSessionReference(backendID: "test", sessionID: "window-close")
    let tab = makeAgentTab(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      title: "Codex",
      command: "codex --yolo",
      sandboxed: true,
      terminalSession: session,
      keepsRunningAfterQuit: true
    )

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [tab]

    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

    #expect(tab.terminalSession == session)
    #expect(stoppedSessions.sessions.isEmpty)
  }

  @Test("app termination window close keeps persistent terminal sessions for restore")
  @MainActor
  func appTerminationWindowCloseKeepsPersistentTerminalSessionsForRestore() throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let suiteName = "WorkspaceWindowRegistryTests.appTerminationWindowClose"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let registry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()
    let session = TerminalSessionReference(backendID: "test", sessionID: "window-restore")
    let tab = makeAgentTab(
      id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      title: "Codex",
      command: "codex --yolo",
      sandboxed: true,
      terminalSession: session,
      keepsRunningAfterQuit: true
    )
    tab.agentActivityState = .thinking

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [tab]

    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)
    registry.prepareForAppTermination(keepRunningAgentsAlive: true)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    registry.unregister(window: window, repoRoot: target.repoRoot)

    let data = try #require(defaults.data(forKey: suiteName))
    let snapshots = try JSONDecoder().decode([PersistedWorkspaceWindowSnapshot].self, from: data)
    let snapshot = try #require(snapshots.first)
    let tabs = try #require(snapshot.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"])
    let persistedTab = try #require(tabs.first { $0.id == tab.id })
    let persistedSession = try #require(persistedTab.terminalSession)

    #expect(persistedSession.sessionID == session.sessionID)
    #expect(TerminalSessionBackends.wasPreservedForRestore(reference: persistedSession))
  }

  @Test("app termination resumes idle persistent sessions without prompting")
  @MainActor
  func appTerminationResumesIdlePersistentSessionsWithoutPrompt() throws {
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    defer {
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
    }

    let suiteName = "WorkspaceWindowRegistryTests.idlePersistentAppTermination"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let registry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()
    let session = TerminalSessionReference(backendID: "test", sessionID: "idle-app-quit")
    let tab = makeAgentTab(
      id: UUID(uuidString: "22222222-3333-4444-5555-666666666667")!,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      title: "Codex",
      command: "codex --yolo",
      sandboxed: true,
      terminalSession: session,
      keepsRunningAfterQuit: true
    )

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [tab]
    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)

    #expect(registry.quitAgentSummary == .empty)
    #expect(
      ArgonTerminationCoordinator.shared.applicationShouldTerminate(NSApplication.shared)
        == .terminateNow)
    #expect(stoppedSessions.sessions == [session])
    #expect(tab.terminalSession == nil)

    let data = try #require(defaults.data(forKey: suiteName))
    let snapshots = try JSONDecoder().decode([PersistedWorkspaceWindowSnapshot].self, from: data)
    let snapshot = try #require(snapshots.first)
    let tabs = try #require(snapshot.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"])
    let persistedTab = try #require(tabs.first { $0.id == tab.id })

    #expect(persistedTab.terminalSession == nil)
    #expect(persistedTab.keepsRunningAfterQuit)
  }

  @Test("app termination preserves hidden persistent workspace sessions")
  @MainActor
  func appTerminationPreservesHiddenPersistentWorkspaceSessions() async throws {
    let restoreExperiment = setExperimentalPersistentAgentTerminalsForTest(true)
    defer { restoreExperiment() }

    let suiteName = "WorkspaceWindowRegistryTests.hiddenPersistentTermination"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let registry = WorkspaceWindowRegistry(
      userDefaults: defaults,
      storageKey: suiteName,
      unregisterPersistenceDelay: .milliseconds(10)
    )
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()
    let session = TerminalSessionReference(backendID: "test", sessionID: "hidden-restore")
    let tab = makeAgentTab(
      id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      title: "Codex",
      command: "codex --yolo",
      sandboxed: true,
      terminalSession: session,
      keepsRunningAfterQuit: true
    )
    tab.agentActivityState = .thinking

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [tab]

    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    registry.unregister(window: window, repoRoot: target.repoRoot)
    try? await Task.sleep(for: .milliseconds(30))

    registry.prepareForAppTermination(keepRunningAgentsAlive: true)

    let data = try #require(defaults.data(forKey: suiteName))
    let snapshots = try JSONDecoder().decode([PersistedWorkspaceWindowSnapshot].self, from: data)
    let snapshot = try #require(snapshots.first)
    let tabs = try #require(snapshot.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"])
    let persistedTab = try #require(tabs.first { $0.id == tab.id })
    let persistedSession = try #require(persistedTab.terminalSession)

    #expect(persistedSession.sessionID == session.sessionID)
    #expect(TerminalSessionBackends.wasPreservedForRestore(reference: persistedSession))
  }

  @Test("app termination preserves hidden stopped agents for restore")
  @MainActor
  func appTerminationPreservesHiddenStoppedAgentsForRestore() async throws {
    let suiteName = "WorkspaceWindowRegistryTests.hiddenStoppedTermination"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let stoppedSessions = TerminalSessionStopRecorder()
    WorkspaceState.terminalSessionStopper = { session in
      stoppedSessions.append(session)
    }
    defer {
      WorkspaceState.terminalSessionStopper = { session in
        TerminalSessionBackends.stop(reference: session)
      }
      defaults.removePersistentDomain(forName: suiteName)
    }

    let registry = WorkspaceWindowRegistry(
      userDefaults: defaults,
      storageKey: suiteName,
      unregisterPersistenceDelay: .milliseconds(10)
    )
    let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-b")
    let state = registry.workspaceState(for: target)
    let window = NSWindow()
    let session = TerminalSessionReference(backendID: "test", sessionID: "hidden-stopped")
    let tab = makeAgentTab(
      id: UUID(uuidString: "33333333-4444-5555-6666-777777777778")!,
      worktreePath: "/tmp/repo-worktrees/feature-b",
      title: "Codex",
      command: "codex --yolo",
      sandboxed: true,
      agentFamilyID: .codex,
      resumeArgumentTemplate: "resume {{session_id}}",
      resumeSessionID: "66666666-6666-6666-6666-666666666666",
      resumeCommandDescription: "codex --yolo resume '66666666-6666-6666-6666-666666666666'",
      terminalSession: session,
      keepsRunningAfterQuit: true
    )
    tab.agentActivityState = .thinking

    state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
    state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [tab]

    registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    registry.unregister(window: window, repoRoot: target.repoRoot)

    registry.closeThinkingAgentTabs()
    registry.prepareForAppTermination(keepRunningAgentsAlive: false)

    let data = try #require(defaults.data(forKey: suiteName))
    let snapshots = try JSONDecoder().decode([PersistedWorkspaceWindowSnapshot].self, from: data)
    let snapshot = try #require(snapshots.first)
    let tabs = try #require(snapshot.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"])
    let persistedTab = try #require(tabs.first { $0.id == tab.id })

    #expect(stoppedSessions.sessions == [session])
    #expect(persistedTab.terminalSession == nil)
    #expect(persistedTab.resumeSessionID == "66666666-6666-6666-6666-666666666666")
  }

  @Test("app termination preserves cold-restore snapshots even after windows unregister")
  @MainActor
  func appTerminationPreservesColdRestoreSnapshotsEvenAfterWindowsUnregister() async {
    let suiteName = "WorkspaceWindowRegistryTests.appTermination"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    do {
      let registry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
      let target = makeTarget(selectedWorktreePath: "/tmp/repo-worktrees/feature-a")
      let state = registry.workspaceState(for: target)
      let window = NSWindow()

      state.selectedWorktreePath = "/tmp/repo-worktrees/feature-b"
      state.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] = [
        makeShellTab(
          id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
          worktreePath: "/tmp/repo-worktrees/feature-b",
          title: "Shell 1",
          sandboxed: true
        ),
        makeShellTab(
          id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
          worktreePath: "/tmp/repo-worktrees/feature-b",
          title: "Privileged Shell 1",
          sandboxed: false
        ),
        makeAgentTab(
          id: UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!,
          worktreePath: "/tmp/repo-worktrees/feature-b",
          title: "Codex",
          command: "/bin/sh -lc 'printf restored\\n'",
          sandboxed: true
        ),
      ]
      state.selectedTerminalTabIDsByWorktreePath["/tmp/repo-worktrees/feature-b"] =
        UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

      registry.register(window: window, workspaceState: state, repoRoot: target.repoRoot)
      NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
      registry.unregister(window: window, repoRoot: target.repoRoot)
    }

    let restoredRegistry = WorkspaceWindowRegistry(userDefaults: defaults, storageKey: suiteName)
    let target = makeTarget(selectedWorktreePath: "/tmp/repo")
    var openedTargets: [WorkspaceTarget] = []

    #expect(
      restoredRegistry.restorePersistedWorkspacesIfNeeded { restoredTarget in
        openedTargets.append(restoredTarget)
      } == 1
    )
    #expect(
      openedTargets == [
        WorkspaceTarget(
          repoRoot: "/tmp/repo",
          repoCommonDir: "/tmp/repo/.git",
          selectedWorktreePath: "/tmp/repo-worktrees/feature-b"
        )
      ])

    let restoredState = restoredRegistry.workspaceState(for: target)
    #expect(restoredState.selectedWorktreePath == "/tmp/repo-worktrees/feature-b")
    #expect(restoredState.allTerminalTabs.isEmpty)

    restoredState.prepareSelectionLoading(for: "/tmp/repo-worktrees/feature-b")
    #expect(
      await waitUntil {
        restoredState.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"] != nil
      }
    )

    #expect(
      restoredState.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"]?.map { $0.title }
        == [
          "Shell 1",
          "Privileged Shell 1",
          "Codex",
        ])
    #expect(
      restoredState.terminalTabsByWorktreePath["/tmp/repo-worktrees/feature-b"]?.first(where: {
        $0.title == "Codex"
      })?.commandDescription == "/bin/sh -lc 'printf restored\\n'")
    #expect(
      restoredState.selectedTerminalTabIDsByWorktreePath["/tmp/repo-worktrees/feature-b"]
        == UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    )
  }

  private func makeTarget(selectedWorktreePath: String) -> WorkspaceTarget {
    WorkspaceTarget(
      repoRoot: "/tmp/repo",
      repoCommonDir: "/tmp/repo/.git",
      selectedWorktreePath: selectedWorktreePath
    )
  }

  private func makeWorktree(
    path: String,
    branchName: String,
    isBaseWorktree: Bool = false
  ) -> DiscoveredWorktree {
    DiscoveredWorktree(
      path: path,
      branchName: branchName,
      headSHA: "abc123",
      isBaseWorktree: isBaseWorktree,
      isDetached: false
    )
  }

  @MainActor
  private func makeShellTab(
    id: UUID,
    worktreePath: String,
    title: String,
    sandboxed: Bool
  ) -> WorkspaceTerminalTab {
    WorkspaceTerminalTab(
      id: id,
      worktreePath: worktreePath,
      worktreeLabel: "feature-b",
      title: title,
      commandDescription: sandboxed ? "Sandboxed /bin/zsh" : "/bin/zsh",
      kind: .shell,
      launch: sandboxed
        ? .sandboxedShell(currentDirectory: worktreePath, writableRoots: [worktreePath])
        : .shell(currentDirectory: worktreePath),
      isSandboxed: sandboxed,
      writableRoots: sandboxed ? [worktreePath] : []
    )
  }

  @MainActor
  private func makeAgentTab(
    id: UUID,
    worktreePath: String,
    title: String,
    command: String,
    sandboxed: Bool,
    isRestorableAfterRelaunch: Bool = true,
    agentFamilyID: AgentFamilyID? = nil,
    resumeArgumentTemplate: String = "",
    resumeSessionID: String? = nil,
    resumeCommandDescription: String? = nil,
    terminalSession: TerminalSessionReference? = nil,
    keepsRunningAfterQuit: Bool = false
  ) -> WorkspaceTerminalTab {
    WorkspaceTerminalTab(
      id: id,
      worktreePath: worktreePath,
      worktreeLabel: "feature-b",
      title: title,
      commandDescription: command,
      kind: .agent(profileName: "Codex", icon: "codex"),
      agentFamilyID: agentFamilyID,
      launch: sandboxed
        ? .sandboxedCommand(command, currentDirectory: worktreePath, writableRoots: [worktreePath])
        : .command(command, currentDirectory: worktreePath),
      isSandboxed: sandboxed,
      writableRoots: sandboxed ? [worktreePath] : [],
      isRestorableAfterRelaunch: isRestorableAfterRelaunch,
      resumeArgumentTemplate: resumeArgumentTemplate,
      keepsRunningAfterQuit: keepsRunningAfterQuit,
      terminalSession: terminalSession,
      resumeSessionID: resumeSessionID,
      resumeCommandDescription: resumeCommandDescription
    )
  }

  @MainActor
  private func setExperimentalPersistentAgentTerminalsForTest(_ enabled: Bool) -> () -> Void {
    let previous = UserDefaults.standard.object(
      forKey: AgentTerminalPersistenceExperimentSettings.enabledStorageKey
    )
    UserDefaults.standard.set(
      enabled,
      forKey: AgentTerminalPersistenceExperimentSettings.enabledStorageKey
    )
    return {
      if let previous {
        UserDefaults.standard.set(
          previous,
          forKey: AgentTerminalPersistenceExperimentSettings.enabledStorageKey
        )
      } else {
        UserDefaults.standard.removeObject(
          forKey: AgentTerminalPersistenceExperimentSettings.enabledStorageKey
        )
      }
    }
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
      if await condition() {
        return true
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    return await condition()
  }
}
