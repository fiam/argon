import AppKit
import Testing

@testable import Argon

@Suite("ReviewWindowRegistry")
struct ReviewWindowRegistryTests {

  @Test("window state moves from opening to open to idle")
  @MainActor
  func windowStateMovesFromOpeningToOpenToIdle() {
    let registry = ReviewWindowRegistry()
    let repoRoot = "/tmp/repo"
    let window = NSWindow()

    #expect(registry.state(for: repoRoot) == .idle)

    registry.markOpening(repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .opening)

    registry.register(window: window, repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .open)

    registry.unregister(window: window, repoRoot: repoRoot)
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
    let firstWindow = NSWindow()
    let secondWindow = NSWindow()

    registry.register(window: firstWindow, repoRoot: repoRoot)
    registry.register(window: secondWindow, repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .open)

    registry.unregister(window: firstWindow, repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .open)

    registry.unregister(window: secondWindow, repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .idle)
  }

  @Test("registering the same window twice does not require double close")
  @MainActor
  func registeringTheSameWindowTwiceDoesNotRequireDoubleClose() {
    let registry = ReviewWindowRegistry()
    let repoRoot = "/tmp/repo"
    let window = NSWindow()

    registry.register(window: window, repoRoot: repoRoot)
    registry.register(window: window, repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .open)

    registry.unregister(window: window, repoRoot: repoRoot)
    #expect(registry.state(for: repoRoot) == .idle)
  }
}
