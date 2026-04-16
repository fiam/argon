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

  @Test("open reuses an existing review window instead of opening another one")
  @MainActor
  func openReusesExistingReviewWindowInsteadOfOpeningAnotherOne() {
    let registry = ReviewWindowRegistry()
    let repoRoot = "/tmp/repo"
    let window = NSWindow()
    let target = ReviewTarget(sessionId: "session-123", repoRoot: repoRoot)
    var openCount = 0

    registry.register(window: window, repoRoot: repoRoot)
    registry.open(target: target) { _ in
      openCount += 1
    }

    #expect(openCount == 0)
    #expect(registry.state(for: repoRoot) == .open)
  }

  @Test("open only requests one new window while a review is opening")
  @MainActor
  func openOnlyRequestsOneNewWindowWhileAReviewIsOpening() {
    let registry = ReviewWindowRegistry()
    let target = ReviewTarget(sessionId: "session-123", repoRoot: "/tmp/repo")
    var openCount = 0

    registry.open(target: target) { _ in
      openCount += 1
    }
    registry.open(target: target) { _ in
      openCount += 1
    }

    #expect(openCount == 1)
    #expect(registry.state(for: target.repoRoot) == .opening)
  }

  @Test("closing a registered review window clears it from the registry")
  @MainActor
  func closingARegisteredReviewWindowClearsItFromTheRegistry() {
    let registry = ReviewWindowRegistry()
    let repoRoot = "/tmp/repo"
    let window = NSWindow()
    let target = ReviewTarget(sessionId: "session-123", repoRoot: repoRoot)
    var openCount = 0

    registry.register(window: window, repoRoot: repoRoot)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

    #expect(registry.state(for: repoRoot) == .idle)

    registry.open(target: target) { _ in
      openCount += 1
    }

    #expect(openCount == 1)
    #expect(registry.state(for: repoRoot) == .opening)
  }
}
