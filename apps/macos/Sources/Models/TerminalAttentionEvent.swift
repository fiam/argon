import Foundation

enum TerminalAttentionEvent: Equatable, Sendable {
  case bell
  case desktopNotification(title: String, body: String)
  case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
}
