import Foundation
import Testing

@testable import Argon

@Suite("WorkspaceTerminalAttentionRouting")
struct WorkspaceTerminalAttentionRoutingTests {
  @Test("visible bell events stay local")
  func visibleBellEventsStayLocal() {
    #expect(
      WorkspaceTerminalAttentionRouting.disposition(
        for: .bell,
        isVisibleTerminal: true
      ) == .localBell
    )
  }

  @Test("hidden bell events notify and mark attention")
  func hiddenBellEventsNotifyAndMarkAttention() {
    #expect(
      WorkspaceTerminalAttentionRouting.disposition(
        for: .bell,
        isVisibleTerminal: false
      ) == .notifyAndMarkAttention
    )
  }

  @Test("non bell events still notify even when visible")
  func nonBellEventsStillNotifyEvenWhenVisible() {
    #expect(
      WorkspaceTerminalAttentionRouting.disposition(
        for: .commandFinished(exitCode: 0, durationNanoseconds: 1),
        isVisibleTerminal: true
      ) == .notifyAndMarkAttention
    )
  }
}
