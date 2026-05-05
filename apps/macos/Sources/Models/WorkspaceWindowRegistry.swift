import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceWindowRegistry {
  struct WindowCloseDecision: Equatable {
    let shouldClose: Bool
    let shouldStopAgents: Bool

    static let close = WindowCloseDecision(shouldClose: true, shouldStopAgents: false)
    static let closeAndStopAgents = WindowCloseDecision(
      shouldClose: true,
      shouldStopAgents: true
    )
    static let cancel = WindowCloseDecision(shouldClose: false, shouldStopAgents: false)
  }

  private final class Registration {
    weak var window: NSWindow?
    let workspaceState: WorkspaceState
    private let windowCloseDelegate: WorkspaceWindowCloseDelegate
    private let windowWillCloseObserver: NSObjectProtocol

    init(
      window: NSWindow,
      workspaceState: WorkspaceState,
      windowCloseDelegate: WorkspaceWindowCloseDelegate,
      windowWillCloseObserver: NSObjectProtocol
    ) {
      self.window = window
      self.workspaceState = workspaceState
      self.windowCloseDelegate = windowCloseDelegate
      self.windowWillCloseObserver = windowWillCloseObserver
    }

    deinit {
      NotificationCenter.default.removeObserver(windowWillCloseObserver)
    }

    @MainActor
    func restoreWindowDelegateIfNeeded() {
      if let window, window.delegate === windowCloseDelegate {
        window.delegate = windowCloseDelegate.previousDelegate
      }
    }
  }

  private final class WorkspaceWindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var registry: WorkspaceWindowRegistry?
    weak var previousDelegate: (any NSWindowDelegate)?
    let repoRoot: String

    init(
      registry: WorkspaceWindowRegistry,
      repoRoot: String,
      previousDelegate: (any NSWindowDelegate)?
    ) {
      self.registry = registry
      self.repoRoot = repoRoot
      self.previousDelegate = previousDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      guard registry?.windowShouldClose(sender, repoRoot: repoRoot) != false else {
        return false
      }

      return previousDelegate?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
      previousDelegate?.windowWillClose?(notification)
    }
  }

  private static let defaultStorageKey = "persistedWorkspaceWindows"
  private static let uiTestSnapshotEnvironmentKey = "ARGON_UI_TEST_WORKSPACE_SNAPSHOT_FILE"

  @ObservationIgnored
  private let userDefaults: UserDefaults
  @ObservationIgnored
  private let storageKey: String
  @ObservationIgnored
  private let unregisterPersistenceDelay: Duration
  @ObservationIgnored
  private let openRequestTimeout: Duration
  @ObservationIgnored
  private let windowCloseConfirmation:
    @MainActor (WorkspaceQuitAgentSummary, NSWindow) -> WindowCloseDecision
  @ObservationIgnored
  nonisolated(unsafe) private var appWillTerminateObserver: NSObjectProtocol?
  @ObservationIgnored
  private var hasAttemptedRestore = false
  @ObservationIgnored
  private var isTerminating = false
  @ObservationIgnored
  private var appTerminationKeepsRunningAgentsAlive = false
  @ObservationIgnored
  private var didPrepareTerminalSessionsForTermination = false
  @ObservationIgnored
  private var pendingUnregisterPersistenceTask: Task<Void, Never>?
  @ObservationIgnored
  private var openRequestTimeoutTasksByRepoRoot: [String: Task<Void, Never>] = [:]
  @ObservationIgnored
  private var openingRepoRoots = Set<String>()
  @ObservationIgnored
  private var pendingTargetsByRepoRoot: [String: WorkspaceTarget] = [:]
  @ObservationIgnored
  private var persistedSnapshotsByRepoRoot: [String: PersistedWorkspaceWindowSnapshot]?
  @ObservationIgnored
  private let uiTestSeededSnapshotsByRepoRoot: [String: PersistedWorkspaceWindowSnapshot]?
  @ObservationIgnored
  private var registrationsByRepoRoot: [String: Registration] = [:]
  @ObservationIgnored
  private var workspaceStatesByRepoRoot: [String: WorkspaceState] = [:]

  init(
    userDefaults: UserDefaults = .standard,
    storageKey: String = defaultStorageKey,
    unregisterPersistenceDelay: Duration = .seconds(1),
    openRequestTimeout: Duration = .seconds(5),
    windowCloseConfirmation:
      @escaping @MainActor (
        WorkspaceQuitAgentSummary,
        NSWindow
      ) -> WindowCloseDecision = WorkspaceWindowRegistry.presentWindowCloseConfirmation
  ) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
    self.unregisterPersistenceDelay = unregisterPersistenceDelay
    self.openRequestTimeout = openRequestTimeout
    self.windowCloseConfirmation = windowCloseConfirmation
    self.uiTestSeededSnapshotsByRepoRoot = Self.loadUITestSeededSnapshots()
    ArgonTerminationCoordinator.shared.register(workspaceWindowRegistry: self)
    appWillTerminateObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleAppWillTerminate()
      }
    }
  }

  deinit {
    if let appWillTerminateObserver {
      NotificationCenter.default.removeObserver(appWillTerminateObserver)
    }
  }

  func workspaceState(for target: WorkspaceTarget) -> WorkspaceState {
    let repoRoot = normalizedPath(target.repoRoot)
    if let workspaceState = workspaceStatesByRepoRoot[repoRoot] {
      if let snapshot = peekPersistedSnapshot(for: repoRoot) {
        if workspaceState.canSeedFromPersistedWindowSnapshot {
          _ = consumePersistedSnapshot(for: repoRoot)
          workspaceState.applyPersistedWindowSnapshot(snapshot)
        } else {
          _ = consumePersistedSnapshot(for: repoRoot)
          workspaceState.mergePersistedRunningAgentTabs(from: snapshot)
        }
      }
      return workspaceState
    }

    let workspaceState = WorkspaceState(target: target)
    configureWorkspaceState(workspaceState, repoRoot: repoRoot)
    if let snapshot = consumePersistedSnapshot(for: repoRoot) {
      workspaceState.applyPersistedWindowSnapshot(snapshot)
    }
    workspaceStatesByRepoRoot[repoRoot] = workspaceState
    return workspaceState
  }

  func restorePersistedWorkspacesIfNeeded(openWindow: (WorkspaceTarget) -> Void) -> Int {
    guard !hasAttemptedRestore else { return 0 }
    hasAttemptedRestore = true

    let snapshots = remainingPersistedSnapshots().filter { snapshot in
      let repoRoot = normalizedPath(snapshot.target.repoRoot)
      return registrationsByRepoRoot[repoRoot] == nil
        && workspaceStatesByRepoRoot[repoRoot] == nil
        && !openingRepoRoots.contains(repoRoot)
    }
    guard !snapshots.isEmpty else { return 0 }

    for snapshot in snapshots {
      _ = workspaceState(for: snapshot.target)
      open(target: snapshot.target, openWindow: openWindow)
    }

    return snapshots.count
  }

  func open(target: WorkspaceTarget, openWindow: (WorkspaceTarget) -> Void) {
    pendingUnregisterPersistenceTask?.cancel()
    let repoRoot = normalizedPath(target.repoRoot)

    if let registration = registrationsByRepoRoot[repoRoot],
      let window = registration.window
    {
      let workspaceState = registration.workspaceState
      pendingTargetsByRepoRoot.removeValue(forKey: repoRoot)
      workspaceState.applyLaunchTarget(target)
      bringToFront(window)
      persistOpenWorkspaces()
      return
    }

    registrationsByRepoRoot[repoRoot]?.restoreWindowDelegateIfNeeded()
    registrationsByRepoRoot.removeValue(forKey: repoRoot)
    let resolvedTarget =
      if let workspaceState = workspaceStatesByRepoRoot[repoRoot] {
        target.restoringSelectedWorktreePath(workspaceState.selectedWorktreePath)
      } else {
        target
      }
    pendingTargetsByRepoRoot[repoRoot] = resolvedTarget

    guard !openingRepoRoots.contains(repoRoot) else { return }
    openingRepoRoots.insert(repoRoot)
    scheduleOpenRequestTimeout(for: repoRoot)
    openWindow(resolvedTarget)
  }

  func register(window: NSWindow, workspaceState: WorkspaceState, repoRoot: String) {
    pendingUnregisterPersistenceTask?.cancel()
    let normalizedRepoRoot = normalizedPath(repoRoot)
    configureWorkspaceState(workspaceState, repoRoot: normalizedRepoRoot)
    workspaceState.finishTerminalDetach()
    workspaceStatesByRepoRoot[normalizedRepoRoot] = workspaceState
    let previousDelegate =
      (window.delegate as? WorkspaceWindowCloseDelegate)?.previousDelegate
      ?? window.delegate
    let windowCloseDelegate = WorkspaceWindowCloseDelegate(
      registry: self,
      repoRoot: normalizedRepoRoot,
      previousDelegate: previousDelegate
    )
    window.delegate = windowCloseDelegate
    let windowWillCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self, weak window] _ in
      MainActor.assumeIsolated {
        guard let self, let window else { return }
        self.handleWindowWillClose(window: window, repoRoot: normalizedRepoRoot)
      }
    }
    registrationsByRepoRoot[normalizedRepoRoot] = Registration(
      window: window,
      workspaceState: workspaceState,
      windowCloseDelegate: windowCloseDelegate,
      windowWillCloseObserver: windowWillCloseObserver
    )
    cancelOpenRequestTimeout(for: normalizedRepoRoot)
    openingRepoRoots.remove(normalizedRepoRoot)

    if let pendingTarget = pendingTargetsByRepoRoot[normalizedRepoRoot] {
      workspaceState.applyLaunchTarget(pendingTarget)
      pendingTargetsByRepoRoot.removeValue(forKey: normalizedRepoRoot)
    }

    persistOpenWorkspaces()
  }

  func unregister(window: NSWindow?, repoRoot: String) {
    let normalizedRepoRoot = normalizedPath(repoRoot)
    cancelOpenRequestTimeout(for: normalizedRepoRoot)
    openingRepoRoots.remove(normalizedRepoRoot)
    guard !isTerminating else { return }

    guard let registration = registrationsByRepoRoot[normalizedRepoRoot] else { return }
    guard
      registration.window == nil
        || window == nil
        || registration.window === window
    else { return }
    registration.restoreWindowDelegateIfNeeded()
    registrationsByRepoRoot.removeValue(forKey: normalizedRepoRoot)
    schedulePersistAfterUnregister()
  }

  func windowShouldClose(_ window: NSWindow, repoRoot: String) -> Bool {
    guard !isTerminating else { return true }
    let normalizedRepoRoot = normalizedPath(repoRoot)
    guard let registration = registrationsByRepoRoot[normalizedRepoRoot],
      registration.window === window
    else {
      return true
    }

    let closeSummary = registration.workspaceState.quitAgentSummary
    guard closeSummary.needsPrompt else { return true }

    let decision = windowCloseConfirmation(closeSummary, window)
    if decision.shouldClose && decision.shouldStopAgents {
      registration.workspaceState.closeThinkingAgentTabs()
    }
    return decision.shouldClose
  }

  func notificationContext(for repoRoot: String) -> WorkspaceTerminalNotificationContext {
    let normalizedRepoRoot = normalizedPath(repoRoot)
    let openProjectCount = registrationsByRepoRoot.values
      .filter { $0.window != nil }
      .count
    let worktreeCount = workspaceStatesByRepoRoot[normalizedRepoRoot]?.worktrees.count ?? 0

    return WorkspaceTerminalNotificationContext(
      showsProject: openProjectCount > 1,
      showsWorkspace: worktreeCount > 1
    )
  }

  var runningPersistentAgentCount: Int {
    workspaceStatesByRepoRoot.values.reduce(0) { count, workspaceState in
      count + workspaceState.runningPersistentAgentCount
    }
  }

  var quitAgentSummary: WorkspaceQuitAgentSummary {
    workspaceStatesByRepoRoot.values.reduce(.empty) { summary, workspaceState in
      let workspaceSummary = workspaceState.quitAgentSummary
      return WorkspaceQuitAgentSummary(
        warningCount: summary.warningCount + workspaceSummary.warningCount,
        keepRunningCount: summary.keepRunningCount + workspaceSummary.keepRunningCount,
        thinkingCount: summary.thinkingCount + workspaceSummary.thinkingCount
      )
    }
  }

  func prepareForAppTermination(keepRunningAgentsAlive: Bool) {
    beginAppTermination(keepRunningAgentsAlive: keepRunningAgentsAlive)
  }

  func closeThinkingAgentTabs() {
    for workspaceState in workspaceStatesByRepoRoot.values {
      workspaceState.closeThinkingAgentTabs()
    }
  }

  @discardableResult
  func focusTerminal(repoRoot: String, worktreePath: String, tabID: UUID) -> Bool {
    let normalizedRepoRoot = normalizedPath(repoRoot)
    guard let workspaceState = workspaceStatesByRepoRoot[normalizedRepoRoot] else {
      return false
    }

    guard workspaceState.focusTerminal(tabID: tabID, in: worktreePath) else {
      return false
    }

    guard let registration = registrationsByRepoRoot[normalizedRepoRoot] else { return false }
    guard let window = registration.window else {
      registration.restoreWindowDelegateIfNeeded()
      registrationsByRepoRoot.removeValue(forKey: normalizedRepoRoot)
      return false
    }
    bringToFront(window)
    return true
  }

  private func configureWorkspaceState(_ workspaceState: WorkspaceState, repoRoot: String) {
    workspaceState.onRestorableStateChange = { [weak self] in
      guard let self else { return }
      self.persistOpenWorkspaces()
    }
    workspaceStatesByRepoRoot[repoRoot] = workspaceState
  }

  private func persistOpenWorkspaces() {
    guard !isTerminating else { return }
    pendingUnregisterPersistenceTask?.cancel()
    persistRegisteredWorkspaceSnapshots()
  }

  private func handleAppWillTerminate() {
    beginAppTermination(keepRunningAgentsAlive: quitAgentSummary.keepRunningCount > 0)
  }

  private func beginAppTermination(keepRunningAgentsAlive: Bool) {
    guard !isTerminating else { return }
    isTerminating = true
    appTerminationKeepsRunningAgentsAlive = keepRunningAgentsAlive
    pendingUnregisterPersistenceTask?.cancel()
    for task in openRequestTimeoutTasksByRepoRoot.values {
      task.cancel()
    }
    openRequestTimeoutTasksByRepoRoot.removeAll()
    prepareTerminalSessionsForTermination(keepRunningAgentsAlive: keepRunningAgentsAlive)
    persistRegisteredWorkspaceSnapshots(
      includeHiddenRestorableWorkspaces: true
    )
  }

  private func handleWindowWillClose(window: NSWindow, repoRoot: String) {
    guard let registration = registrationsByRepoRoot[repoRoot] else { return }
    guard registration.window === window else { return }
    guard isTerminating else { return }

    registration.workspaceState.prepareTerminalSessionsForTermination(
      keepRunningAgentsAlive: isTerminating && appTerminationKeepsRunningAgentsAlive
    )

    persistRegisteredWorkspaceSnapshots(
      includeHiddenRestorableWorkspaces: appTerminationKeepsRunningAgentsAlive
    )
  }

  private func prepareTerminalSessionsForTermination(keepRunningAgentsAlive: Bool) {
    guard !didPrepareTerminalSessionsForTermination else { return }
    didPrepareTerminalSessionsForTermination = true
    for workspaceState in workspaceStatesByRepoRoot.values {
      workspaceState.prepareTerminalSessionsForTermination(
        keepRunningAgentsAlive: keepRunningAgentsAlive
      )
    }
  }

  private func schedulePersistAfterUnregister() {
    pendingUnregisterPersistenceTask?.cancel()
    let delay = unregisterPersistenceDelay
    pendingUnregisterPersistenceTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled, !self.isTerminating else { return }
      self.persistRegisteredWorkspaceSnapshots()
      self.pendingUnregisterPersistenceTask = nil
    }
  }

  private func persistRegisteredWorkspaceSnapshots(
    includeHiddenRestorableWorkspaces: Bool = false
  ) {
    var snapshotsByRepoRoot = registrationsByRepoRoot.reduce(
      into: [String: PersistedWorkspaceWindowSnapshot]()
    ) { partialResult, entry in
      let (repoRoot, registration) = entry
      guard registration.window != nil else { return }
      partialResult[repoRoot] = registration.workspaceState.persistedWindowSnapshot
    }

    if includeHiddenRestorableWorkspaces {
      for (repoRoot, workspaceState) in workspaceStatesByRepoRoot {
        guard snapshotsByRepoRoot[repoRoot] == nil else { continue }
        guard
          workspaceState.quitAgentSummary.keepRunningCount > 0
            || workspaceState.hasPendingRestorableTerminalTabs
        else { continue }
        let snapshot = workspaceState.persistedWindowSnapshot
        guard snapshot.terminalTabsByWorktreePath.values.contains(where: { !$0.isEmpty })
        else { continue }
        snapshotsByRepoRoot[repoRoot] = snapshot
      }
    }

    let snapshots =
      snapshotsByRepoRoot
      .sorted { $0.key < $1.key }
      .map { $0.value }

    if let data = try? JSONEncoder().encode(snapshots) {
      userDefaults.set(data, forKey: storageKey)
    }
    persistedSnapshotsByRepoRoot = Dictionary(
      uniqueKeysWithValues: snapshots.map { snapshot in
        (normalizedPath(snapshot.target.repoRoot), snapshot)
      }
    )
  }

  private func remainingPersistedSnapshots() -> [PersistedWorkspaceWindowSnapshot] {
    loadPersistedSnapshotsIfNeeded()
    return persistedSnapshotsByRepoRoot?
      .values
      .sorted { normalizedPath($0.target.repoRoot) < normalizedPath($1.target.repoRoot) } ?? []
  }

  private func consumePersistedSnapshot(for repoRoot: String) -> PersistedWorkspaceWindowSnapshot? {
    loadPersistedSnapshotsIfNeeded()
    return persistedSnapshotsByRepoRoot?.removeValue(forKey: repoRoot)
  }

  private func peekPersistedSnapshot(for repoRoot: String) -> PersistedWorkspaceWindowSnapshot? {
    loadPersistedSnapshotsIfNeeded()
    return persistedSnapshotsByRepoRoot?[repoRoot]
  }

  private func discardPersistedSnapshot(for repoRoot: String) {
    loadPersistedSnapshotsIfNeeded()
    persistedSnapshotsByRepoRoot?.removeValue(forKey: repoRoot)
  }

  private func loadPersistedSnapshotsIfNeeded() {
    guard persistedSnapshotsByRepoRoot == nil else { return }

    if let uiTestSeededSnapshotsByRepoRoot {
      persistedSnapshotsByRepoRoot = uiTestSeededSnapshotsByRepoRoot
      return
    }

    guard let data = userDefaults.data(forKey: storageKey),
      let snapshots = try? JSONDecoder().decode([PersistedWorkspaceWindowSnapshot].self, from: data)
    else {
      persistedSnapshotsByRepoRoot = [:]
      return
    }

    persistedSnapshotsByRepoRoot = Dictionary(
      uniqueKeysWithValues: snapshots.map { snapshot in
        (normalizedPath(snapshot.target.repoRoot), snapshot)
      }
    )
  }

  private static func loadUITestSeededSnapshots(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: PersistedWorkspaceWindowSnapshot]? {
    guard let path = environment[uiTestSnapshotEnvironmentKey], !path.isEmpty else { return nil }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let snapshots = try? JSONDecoder().decode([PersistedWorkspaceWindowSnapshot].self, from: data)
    else {
      return nil
    }

    return Dictionary(
      uniqueKeysWithValues: snapshots.map { snapshot in
        (normalizedPath(snapshot.target.repoRoot), snapshot)
      }
    )
  }

  private static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func scheduleOpenRequestTimeout(for repoRoot: String) {
    openRequestTimeoutTasksByRepoRoot[repoRoot]?.cancel()
    let timeout = openRequestTimeout
    openRequestTimeoutTasksByRepoRoot[repoRoot] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: timeout)
      guard let self, !Task.isCancelled, !self.isTerminating else { return }
      self.openRequestTimeoutTasksByRepoRoot.removeValue(forKey: repoRoot)
      guard self.registrationsByRepoRoot[repoRoot] == nil else { return }
      self.openingRepoRoots.remove(repoRoot)
    }
  }

  private func cancelOpenRequestTimeout(for repoRoot: String) {
    openRequestTimeoutTasksByRepoRoot[repoRoot]?.cancel()
    openRequestTimeoutTasksByRepoRoot.removeValue(forKey: repoRoot)
  }

  private func bringToFront(_ window: NSWindow) {
    NSApp.activate(ignoringOtherApps: true)
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
  }

  private func normalizedPath(_ path: String) -> String {
    Self.normalizedPath(path)
  }

  private static func presentWindowCloseConfirmation(
    summary: WorkspaceQuitAgentSummary,
    window _: NSWindow
  ) -> WindowCloseDecision {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = closeMessageText(for: summary)
    alert.informativeText = closeInformativeText(for: summary)
    alert.addButton(withTitle: "Close Window")
    alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title =
      summary.warningCount == 1 ? "Stop this agent" : "Stop these agents"
    alert.suppressionButton?.state = .off

    guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
    return alert.suppressionButton?.state == .on ? .closeAndStopAgents : .close
  }

  private static func closeMessageText(for summary: WorkspaceQuitAgentSummary) -> String {
    if summary.thinkingCount > 0 {
      return summary.warningCount == 1
        ? "Agent Is Still Working"
        : "Agents Are Still Working"
    }

    return summary.warningCount == 1
      ? "Agent Is Still Running"
      : "Agents Are Still Running"
  }

  private static func closeInformativeText(for summary: WorkspaceQuitAgentSummary) -> String {
    if summary.keepRunningCount == 0 {
      return summary.warningCount == 1
        ? "Closing this window will hide the working agent. It will keep running while Argon stays open."
        : "Closing this window will hide these \(summary.warningCount) working agents. They will keep running while Argon stays open."
    }

    let persistentText =
      summary.keepRunningCount == 1
      ? "Argon will keep this working agent running in its terminal session and reconnect when you reopen the workspace."
      : "Argon will keep \(summary.keepRunningCount) working agents running in their terminal sessions and reconnect when you reopen the workspace."
    let otherCount = summary.warningCount - summary.keepRunningCount
    guard otherCount > 0 else { return persistentText }

    let otherText =
      otherCount == 1
      ? "One other working agent will keep running while Argon stays open."
      : "\(otherCount) other working agents will keep running while Argon stays open."
    return "\(persistentText) \(otherText)"
  }
}
