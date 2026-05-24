import AppKit
import Testing

@testable import Argon

@Suite("ReviewWindowRegistry")
struct ReviewWindowRegistryTests {

  @Test("window state moves from opening to open to idle")
  @MainActor
  func windowStateMovesFromOpeningToOpenToIdle() {
    let registry = ReviewWindowRegistry()
    let sessionID = "session-123"
    let window = NSWindow()

    #expect(registry.state(forSessionID: sessionID) == .idle)

    registry.markOpening(sessionID: sessionID)
    #expect(registry.state(forSessionID: sessionID) == .opening)

    registry.register(window: window, sessionID: sessionID)
    #expect(registry.state(forSessionID: sessionID) == .open)

    registry.unregister(window: window, sessionID: sessionID)
    #expect(registry.state(forSessionID: sessionID) == .idle)
  }

  @Test("window state normalizes session id case")
  @MainActor
  func windowStateNormalizesSessionIDCase() {
    let registry = ReviewWindowRegistry()

    registry.markOpening(sessionID: "ABC-123")
    #expect(registry.state(forSessionID: "abc-123") == .opening)
  }

  @Test("open state persists until the last window closes")
  @MainActor
  func openStatePersistsUntilLastWindowCloses() {
    let registry = ReviewWindowRegistry()
    let sessionID = "session-123"
    let firstWindow = NSWindow()
    let secondWindow = NSWindow()

    registry.register(window: firstWindow, sessionID: sessionID)
    registry.register(window: secondWindow, sessionID: sessionID)
    #expect(registry.state(forSessionID: sessionID) == .open)

    registry.unregister(window: firstWindow, sessionID: sessionID)
    #expect(registry.state(forSessionID: sessionID) == .open)

    registry.unregister(window: secondWindow, sessionID: sessionID)
    #expect(registry.state(forSessionID: sessionID) == .idle)
  }

  @Test("registering the same window twice does not require double close")
  @MainActor
  func registeringTheSameWindowTwiceDoesNotRequireDoubleClose() {
    let registry = ReviewWindowRegistry()
    let sessionID = "session-123"
    let window = NSWindow()

    registry.register(window: window, sessionID: sessionID)
    registry.register(window: window, sessionID: sessionID)
    #expect(registry.state(forSessionID: sessionID) == .open)

    registry.unregister(window: window, sessionID: sessionID)
    #expect(registry.state(forSessionID: sessionID) == .idle)
  }

  @Test("open reuses an existing review session instead of opening another window")
  @MainActor
  func openReusesExistingReviewSessionInsteadOfOpeningAnotherWindow() {
    let registry = ReviewWindowRegistry()
    let repoRoot = "/tmp/repo"
    let window = NSWindow()
    let target = ReviewTarget(sessionId: "session-123", repoRoot: repoRoot)
    var openCount = 0

    registry.register(window: window, target: target)
    registry.open(target: target) { _ in
      openCount += 1
    }

    #expect(openCount == 0)
    #expect(registry.state(for: target) == .open)
  }

  @Test("open allows different sessions from the same repo")
  @MainActor
  func openAllowsDifferentSessionsFromTheSameRepo() {
    let registry = ReviewWindowRegistry()
    let repoRoot = "/tmp/repo"
    let firstWindow = NSWindow()
    let firstTarget = ReviewTarget(sessionId: "session-123", repoRoot: repoRoot)
    let secondTarget = ReviewTarget(sessionId: "session-456", repoRoot: repoRoot)
    var openedTargets: [ReviewTarget] = []

    registry.register(window: firstWindow, target: firstTarget)
    registry.open(target: secondTarget) { target in
      openedTargets.append(target)
    }

    #expect(openedTargets == [secondTarget])
    #expect(registry.state(for: firstTarget) == .open)
    #expect(registry.state(for: secondTarget) == .opening)
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
    #expect(registry.state(for: target) == .opening)
  }

  @Test("closing a registered review window clears it from the registry")
  @MainActor
  func closingARegisteredReviewWindowClearsItFromTheRegistry() {
    let registry = ReviewWindowRegistry()
    let window = NSWindow()
    let target = ReviewTarget(sessionId: "session-123", repoRoot: "/tmp/repo")
    var openCount = 0

    registry.register(window: window, target: target)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

    #expect(registry.state(for: target) == .idle)

    registry.open(target: target) { _ in
      openCount += 1
    }

    #expect(openCount == 1)
    #expect(registry.state(for: target) == .opening)
  }
}
