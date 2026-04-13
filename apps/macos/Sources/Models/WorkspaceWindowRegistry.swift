import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceWindowRegistry {
  private final class Registration {
    weak var window: NSWindow?
    weak var workspaceState: WorkspaceState?

    init(window: NSWindow, workspaceState: WorkspaceState) {
      self.window = window
      self.workspaceState = workspaceState
    }
  }

  private var openingRepoRoots = Set<String>()
  private var pendingTargetsByRepoRoot: [String: WorkspaceTarget] = [:]
  private var registrationsByRepoRoot: [String: Registration] = [:]

  func open(target: WorkspaceTarget, openWindow: (WorkspaceTarget) -> Void) {
    let repoRoot = normalizedPath(target.repoRoot)

    if let registration = registrationsByRepoRoot[repoRoot],
      let window = registration.window,
      let workspaceState = registration.workspaceState
    {
      pendingTargetsByRepoRoot.removeValue(forKey: repoRoot)
      workspaceState.applyLaunchTarget(target)
      bringToFront(window)
      return
    }

    registrationsByRepoRoot.removeValue(forKey: repoRoot)
    pendingTargetsByRepoRoot[repoRoot] = target

    guard !openingRepoRoots.contains(repoRoot) else { return }
    openingRepoRoots.insert(repoRoot)
    openWindow(target)
  }

  func register(window: NSWindow, workspaceState: WorkspaceState, repoRoot: String) {
    let normalizedRepoRoot = normalizedPath(repoRoot)
    registrationsByRepoRoot[normalizedRepoRoot] = Registration(
      window: window,
      workspaceState: workspaceState
    )
    openingRepoRoots.remove(normalizedRepoRoot)

    if let pendingTarget = pendingTargetsByRepoRoot[normalizedRepoRoot] {
      workspaceState.applyLaunchTarget(pendingTarget)
      pendingTargetsByRepoRoot.removeValue(forKey: normalizedRepoRoot)
    }
  }

  func unregister(window: NSWindow?, repoRoot: String) {
    let normalizedRepoRoot = normalizedPath(repoRoot)
    openingRepoRoots.remove(normalizedRepoRoot)

    guard let registration = registrationsByRepoRoot[normalizedRepoRoot] else { return }
    guard
      registration.window == nil
        || window == nil
        || registration.window === window
    else { return }
    registrationsByRepoRoot.removeValue(forKey: normalizedRepoRoot)
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
