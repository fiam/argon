import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceWindowRegistry {
  private final class Registration {
    weak var window: NSWindow?
    let workspaceState: WorkspaceState

    init(window: NSWindow, workspaceState: WorkspaceState) {
      self.window = window
      self.workspaceState = workspaceState
    }
  }

  private static let defaultStorageKey = "persistedWorkspaceWindows"

  @ObservationIgnored
  private let userDefaults: UserDefaults
  @ObservationIgnored
  private let storageKey: String
  @ObservationIgnored
  private let unregisterPersistenceDelay: Duration
  @ObservationIgnored
  private let openRequestTimeout: Duration
  @ObservationIgnored
  nonisolated(unsafe) private var appWillTerminateObserver: NSObjectProtocol?
  @ObservationIgnored
  private var hasAttemptedRestore = false
  @ObservationIgnored
  private var isTerminating = false
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
  private var registrationsByRepoRoot: [String: Registration] = [:]
  @ObservationIgnored
  private var workspaceStatesByRepoRoot: [String: WorkspaceState] = [:]

  init(
    userDefaults: UserDefaults = .standard,
    storageKey: String = defaultStorageKey,
    unregisterPersistenceDelay: Duration = .seconds(1),
    openRequestTimeout: Duration = .seconds(5)
  ) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
    self.unregisterPersistenceDelay = unregisterPersistenceDelay
    self.openRequestTimeout = openRequestTimeout
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
      if let snapshot = consumePersistedSnapshot(for: repoRoot) {
        workspaceState.applyPersistedWindowSnapshot(snapshot)
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

    let snapshots = remainingPersistedSnapshots()
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
    workspaceStatesByRepoRoot[normalizedRepoRoot] = workspaceState
    registrationsByRepoRoot[normalizedRepoRoot] = Registration(
      window: window,
      workspaceState: workspaceState
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
    registrationsByRepoRoot.removeValue(forKey: normalizedRepoRoot)
    schedulePersistAfterUnregister()
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
    guard !isTerminating else { return }
    isTerminating = true
    pendingUnregisterPersistenceTask?.cancel()
    for task in openRequestTimeoutTasksByRepoRoot.values {
      task.cancel()
    }
    openRequestTimeoutTasksByRepoRoot.removeAll()
    persistRegisteredWorkspaceSnapshots()
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

  private func persistRegisteredWorkspaceSnapshots() {
    let snapshots =
      registrationsByRepoRoot
      .sorted { $0.key < $1.key }
      .compactMap { _, registration -> PersistedWorkspaceWindowSnapshot? in
        guard registration.window != nil else { return nil }
        return registration.workspaceState.persistedWindowSnapshot
      }

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

  private func loadPersistedSnapshotsIfNeeded() {
    guard persistedSnapshotsByRepoRoot == nil else { return }

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
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
