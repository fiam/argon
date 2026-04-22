import Foundation

enum WorkspaceTerminalAttentionDisposition: Equatable {
  case localBell
  case notifyAndMarkAttention
}

enum WorkspaceTerminalAttentionRouting {
  static func disposition(
    for event: TerminalAttentionEvent,
    isVisibleTerminal: Bool
  ) -> WorkspaceTerminalAttentionDisposition {
    switch event {
    case .bell where isVisibleTerminal:
      .localBell
    default:
      .notifyAndMarkAttention
    }
  }
}
