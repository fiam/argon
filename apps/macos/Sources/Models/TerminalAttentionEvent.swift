import Foundation

enum TerminalAttentionEvent: Equatable, Sendable {
  case bell
  case desktopNotification(title: String, body: String)
  case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
}

enum TerminalTitleChange: Equatable, Sendable {
  case window(String)
  case tab(String)

  var title: String {
    switch self {
    case .window(let title), .tab(let title):
      title
    }
  }
}
