import Foundation

enum WorkspaceFinishedTerminalBehavior: String, CaseIterable, Identifiable, Sendable {
  static let storageKey = "workspaceShellExitBehavior"

  case autoClose
  case keepOpen

  var id: String { rawValue }

  var title: String {
    switch self {
    case .autoClose:
      "On"
    case .keepOpen:
      "Off"
    }
  }

  var helpText: String {
    switch self {
    case .autoClose:
      "Close finished agent and shell tabs as soon as their process exits."
    case .keepOpen:
      "Keep finished tabs visible. Shell tabs show inline actions after exit."
    }
  }
}
