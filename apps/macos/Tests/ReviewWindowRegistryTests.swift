import Testing

@testable import Argon

@Suite("ReviewWindowRegistry")
struct ReviewWindowRegistryTests {

  @Test("window state moves from opening to open to idle")
  @MainActor
  func windowStateMovesFromOpeningToOpenToIdle() {
    let registry = ReviewWindowRegistry()
    let repoRoot = "/tmp/repo"

    #expect(registry.state(for: repoRoot) == .idle)

    registry.markOpening(repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .opening)

    registry.markOpened(repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .open)

    registry.markClosed(repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .idle)
  }

  @Test("window state normalizes repo root paths")
  @MainActor
  func windowStateNormalizesRepoRootPaths() {
    let registry = ReviewWindowRegistry()

    registry.markOpening(repoRoot: "/tmp/work/../work/repo")
    #expect(registry.state(for: "/tmp/work/repo") == .opening)
  }

  @Test("open state persists until the last window closes")
  @MainActor
  func openStatePersistsUntilLastWindowCloses() {
    let registry = ReviewWindowRegistry()
    let repoRoot = "/tmp/repo"

    registry.markOpened(repoRoot: repoRoot)
    registry.markOpened(repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .open)

    registry.markClosed(repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .open)

    registry.markClosed(repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .idle)
  }
}
