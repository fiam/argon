import Foundation

struct TerminalSessionReference: Codable, Equatable, Sendable {
  let backendID: String
  let sessionID: String
  let context: [String: String]

  init(
    backendID: String,
    sessionID: String,
    context: [String: String] = [:]
  ) {
    self.backendID = backendID
    self.sessionID = sessionID
    self.context = context
  }
}

protocol TerminalSessionBackend: Sendable {
  var backendID: String { get }

  func isAvailable() -> Bool
  func reference(for tabID: UUID, projectPath: String) -> TerminalSessionReference?
  func stop(reference: TerminalSessionReference)
  func isRunning(reference: TerminalSessionReference) -> Bool
}

enum TerminalSessionBackends {
  private static let preservedForRestoreContextKey = "preservedForRestore"
  private static let argon = ArgonTerminalSessionBackend()
  private static let legacyScreen = LegacyScreenTerminalSessionStopper()

  static func isAvailable() -> Bool {
    argon.isAvailable()
  }

  static func reference(for tabID: UUID, projectPath: String) -> TerminalSessionReference? {
    guard argon.isAvailable() else { return nil }
    return argon.reference(for: tabID, projectPath: projectPath)
  }

  static func attachLaunchConfiguration(
    reference: TerminalSessionReference,
    createLaunch: TerminalLaunchConfiguration
  ) -> TerminalLaunchConfiguration {
    switch reference.backendID {
    case argon.backendID:
      return argon.attachLaunchConfiguration(reference: reference, createLaunch: createLaunch)
    default:
      return createLaunch
    }
  }

  static func canReconnect(reference: TerminalSessionReference) -> Bool {
    reference.backendID == argon.backendID && argon.isAvailable()
  }

  static func isRunning(reference: TerminalSessionReference) -> Bool {
    switch reference.backendID {
    case argon.backendID:
      argon.isRunning(reference: reference)
    default:
      false
    }
  }

  static func markPreservedForRestore(
    reference: TerminalSessionReference
  ) -> TerminalSessionReference {
    var context = reference.context
    context[preservedForRestoreContextKey] = "true"
    return TerminalSessionReference(
      backendID: reference.backendID,
      sessionID: reference.sessionID,
      context: context
    )
  }

  static func wasPreservedForRestore(reference: TerminalSessionReference) -> Bool {
    reference.context[preservedForRestoreContextKey] == "true"
  }

  static func stop(reference: TerminalSessionReference) {
    switch reference.backendID {
    case argon.backendID:
      argon.stop(reference: reference)
    case legacyScreen.backendID:
      legacyScreen.stop(reference: reference)
    default:
      break
    }
  }
}
