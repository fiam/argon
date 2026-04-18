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
    isRestorableAfterRelaunch: Bool = true
  ) -> WorkspaceTerminalTab {
    WorkspaceTerminalTab(
      id: id,
      worktreePath: worktreePath,
      worktreeLabel: "feature-b",
      title: title,
      commandDescription: command,
      kind: .agent(profileName: "Codex", icon: "codex"),
      launch: sandboxed
        ? .sandboxedCommand(command, currentDirectory: worktreePath, writableRoots: [worktreePath])
        : .command(command, currentDirectory: worktreePath),
      isSandboxed: sandboxed,
      writableRoots: sandboxed ? [worktreePath] : [],
      isRestorableAfterRelaunch: isRestorableAfterRelaunch
    )
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
