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
  private var openingSessionIDs = Set<String>()
  @ObservationIgnored
  private var registrationsBySessionID: [String: [Registration]] = [:]

  func open(target: ReviewTarget, openWindow: (ReviewTarget) -> Void) {
    let sessionID = sessionKey(target.sessionId)
    if bringToFront(sessionID: sessionID) {
      return
    }

    guard !openingSessionIDs.contains(sessionID) else { return }
    openingSessionIDs.insert(sessionID)
    openWindow(target)
  }

  func state(forSessionID sessionID: String) -> WindowState {
    let sessionID = sessionKey(sessionID)
    if openingSessionIDs.contains(sessionID) {
      return .opening
    }
    pruneDeadRegistrations(forSessionID: sessionID)
    if !(registrationsBySessionID[sessionID] ?? []).isEmpty {
      return .open
    }
    return .idle
  }

  func state(for target: ReviewTarget) -> WindowState {
    state(forSessionID: target.sessionId)
  }

  func markOpening(sessionID: String) {
    openingSessionIDs.insert(sessionKey(sessionID))
  }

  func register(window: NSWindow, target: ReviewTarget) {
    register(window: window, sessionID: target.sessionId)
  }

  func register(window: NSWindow, sessionID rawSessionID: String) {
    let sessionID = sessionKey(rawSessionID)
    openingSessionIDs.remove(sessionID)
    pruneDeadRegistrations(forSessionID: sessionID)

    if registrationsBySessionID[sessionID]?.contains(where: { $0.window === window }) == true {
      return
    }

    let closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { [weak self, weak window] _ in
      MainActor.assumeIsolated {
        guard let self, let window else { return }
        self.unregister(window: window, sessionID: sessionID)
      }
    }

    registrationsBySessionID[sessionID, default: []].append(
      Registration(window: window, closeObserver: closeObserver)
    )
  }

  func unregister(window: NSWindow, target: ReviewTarget) {
    unregister(window: window, sessionID: target.sessionId)
  }

  func unregister(window: NSWindow, sessionID rawSessionID: String) {
    let sessionID = sessionKey(rawSessionID)
    openingSessionIDs.remove(sessionID)
    guard var registrations = registrationsBySessionID[sessionID] else { return }

    registrations.removeAll { registration in
      registration.window == nil || registration.window === window
    }

    if registrations.isEmpty {
      registrationsBySessionID.removeValue(forKey: sessionID)
    } else {
      registrationsBySessionID[sessionID] = registrations
    }
  }

  @discardableResult
  func bringToFront(sessionID rawSessionID: String) -> Bool {
    let sessionID = sessionKey(rawSessionID)
    pruneDeadRegistrations(forSessionID: sessionID)
    guard
      let window = registrationsBySessionID[sessionID]?
        .compactMap(\.window)
        .last
    else {
      return false
    }

    bringWindowToFront(window)
    return true
  }

  private func pruneDeadRegistrations(forSessionID sessionID: String) {
    guard var registrations = registrationsBySessionID[sessionID] else { return }
    registrations.removeAll { $0.window == nil }
    if registrations.isEmpty {
      registrationsBySessionID.removeValue(forKey: sessionID)
    } else {
      registrationsBySessionID[sessionID] = registrations
    }
  }

  private func bringWindowToFront(_ window: NSWindow) {
    NSApp.activate(ignoringOtherApps: true)
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
  }

  private func sessionKey(_ sessionID: String) -> String {
    sessionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
