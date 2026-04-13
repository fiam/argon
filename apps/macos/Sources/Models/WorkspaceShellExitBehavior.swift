import Foundation

enum WorkspaceShellExitBehavior: String, CaseIterable, Identifiable, Sendable {
  static let storageKey = "workspaceShellExitBehavior"

  case closeTab
  case keepTabOpen

  var id: String { rawValue }

  var title: String {
    switch self {
    case .closeTab:
      "Close Tab"
    case .keepTabOpen:
      "Keep Tab Open"
    }
  }

  var helpText: String {
    switch self {
    case .closeTab:
      "Shell tabs close as soon as the process exits."
    case .keepTabOpen:
      "Keep the transcript visible and show inline actions after the shell exits."
    }
  }
}
