import AppKit
import Foundation

@MainActor
@Observable
final class ReviewWindowRegistry {
  private final class Registration {
    weak var window: NSWindow?

    init(window: NSWindow) {
      self.window = window
    }
  }

  enum WindowState: Equatable {
    case idle
    case opening
    case open
  }

  private var openingRepoRoots = Set<String>()
  private var registrationsByRepoRoot: [String: [Registration]] = [:]

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

    registrationsByRepoRoot[normalized, default: []].append(Registration(window: window))
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

  private func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
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
}
