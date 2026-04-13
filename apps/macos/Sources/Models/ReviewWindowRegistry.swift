import Foundation

@MainActor
@Observable
final class ReviewWindowRegistry {
  enum WindowState: Equatable {
    case idle
    case opening
    case open
  }

  private var openingRepoRoots = Set<String>()
  private var openWindowCountsByRepoRoot: [String: Int] = [:]

  func state(for repoRoot: String) -> WindowState {
    let normalized = normalizedPath(repoRoot)
    if openingRepoRoots.contains(normalized) {
      return .opening
    }
    if (openWindowCountsByRepoRoot[normalized] ?? 0) > 0 {
      return .open
    }
    return .idle
  }

  func markOpening(repoRoot: String) {
    openingRepoRoots.insert(normalizedPath(repoRoot))
  }

  func markOpened(repoRoot: String) {
    let normalized = normalizedPath(repoRoot)
    openingRepoRoots.remove(normalized)
    openWindowCountsByRepoRoot[normalized, default: 0] += 1
  }

  func markClosed(repoRoot: String) {
    let normalized = normalizedPath(repoRoot)
    openingRepoRoots.remove(normalized)

    guard let count = openWindowCountsByRepoRoot[normalized] else { return }
    if count <= 1 {
      openWindowCountsByRepoRoot.removeValue(forKey: normalized)
    } else {
      openWindowCountsByRepoRoot[normalized] = count - 1
    }
  }

  private func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
