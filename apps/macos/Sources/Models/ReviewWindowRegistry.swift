import AppKit
import Foundation

@MainActor
@Observable
final class ReviewWindowRegistry {
  private final class Registration {
    weak var window: NSWindow?
    private let closeObserver: NSObjectProtocol

    init(window: NSWindow, closeObserver: NSObjectProtocol) {
      self.window = window
      self.closeObserver = closeObserver
    }

    deinit {
      NotificationCenter.default.removeObserver(closeObserver)
    }
  }

  enum WindowState: Equatable {
    case idle
    case opening
    case open
  }

  @ObservationIgnored
  private var openingRepoRoots = Set<String>()
  @ObservationIgnored
  private var registrationsByRepoRoot: [String: [Registration]] = [:]

  func open(target: ReviewTarget, openWindow: (ReviewTarget) -> Void) {
    let normalized = normalizedPath(target.repoRoot)
    if bringToFront(repoRoot: normalized) {
      return
    }

    guard !openingRepoRoots.contains(normalized) else { return }
    openingRepoRoots.insert(normalized)
    openWindow(target)
  }

  func state(for repoRoot: String) -> WindowState {
    let normalized = normalizedPath(repoRoot)
    if openingRepoRoots.contains(normalized) {
      return .opening
    }
    pruneDeadRegistrations(for: normalized)
    if !(registrationsByRepoRoot[normalized] ?? []).isEmpty {
      return .open
    }
    return .idle
  }

  func markOpening(repoRoot: String) {
    openingRepoRoots.insert(normalizedPath(repoRoot))
  }

  func register(window: NSWindow, repoRoot: String) {
    let normalized = normalizedPath(repoRoot)
    openingRepoRoots.remove(normalized)
    pruneDeadRegistrations(for: normalized)

    if registrationsByRepoRoot[normalized]?.contains(where: { $0.window === window }) == true {
      return
    }

    let closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self, weak window] _ in
      MainActor.assumeIsolated {
        guard let self, let window else { return }
        self.unregister(window: window, repoRoot: normalized)
      }
    }

    registrationsByRepoRoot[normalized, default: []].append(
      Registration(window: window, closeObserver: closeObserver)
    )
  }

  func unregister(window: NSWindow, repoRoot: String) {
    let normalized = normalizedPath(repoRoot)
    openingRepoRoots.remove(normalized)
    guard var registrations = registrationsByRepoRoot[normalized] else { return }

    registrations.removeAll { registration in
      registration.window == nil || registration.window === window
    }

    if registrations.isEmpty {
      registrationsByRepoRoot.removeValue(forKey: normalized)
    } else {
      registrationsByRepoRoot[normalized] = registrations
    }
  }

  @discardableResult
  func bringToFront(repoRoot: String) -> Bool {
    let normalized = normalizedPath(repoRoot)
    pruneDeadRegistrations(for: normalized)
    guard
      let window = registrationsByRepoRoot[normalized]?
        .compactMap(\.window)
        .last
    else {
      return false
    }

    bringWindowToFront(window)
    return true
  }

  private func pruneDeadRegistrations(for repoRoot: String) {
    guard var registrations = registrationsByRepoRoot[repoRoot] else { return }
    registrations.removeAll { $0.window == nil }
    if registrations.isEmpty {
      registrationsByRepoRoot.removeValue(forKey: repoRoot)
    } else {
      registrationsByRepoRoot[repoRoot] = registrations
    }
  }

  private func bringWindowToFront(_ window: NSWindow) {
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
