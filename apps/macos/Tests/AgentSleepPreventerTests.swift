import Foundation
import Testing

@testable import Argon

@Suite("AgentSleepPreventer")
struct AgentSleepPreventerTests {
  @Test("activating begins one sleep prevention activity")
  @MainActor
  func activatingBeginsOneSleepPreventionActivity() {
    let activityManager = FakeAgentSleepActivityManager()
    let preventer = AgentSleepPreventer(activityManager: activityManager)

    preventer.setActive(true)
    preventer.setActive(true)

    #expect(activityManager.beginCount == 1)
    #expect(activityManager.endCount == 0)
    #expect(activityManager.lastReason == "Argon agents are running")
    #expect(activityManager.lastOptions?.contains(.idleSystemSleepDisabled) == true)
  }

  @Test("deactivating releases the active sleep prevention activity")
  @MainActor
  func deactivatingReleasesTheActiveSleepPreventionActivity() {
    let activityManager = FakeAgentSleepActivityManager()
    let preventer = AgentSleepPreventer(activityManager: activityManager)

    preventer.setActive(true)
    preventer.setActive(false)
    preventer.setActive(false)

    #expect(activityManager.beginCount == 1)
    #expect(activityManager.endCount == 1)
  }
}

private final class FakeAgentSleepActivityManager: AgentSleepActivityManaging {
  private final class Activity: NSObject {}

  private(set) var beginCount = 0
  private(set) var endCount = 0
  private(set) var lastOptions: ProcessInfo.ActivityOptions?
  private(set) var lastReason: String?

  func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
    beginCount += 1
    lastOptions = options
    lastReason = reason
    return Activity()
  }

  func endActivity(_ activity: NSObjectProtocol) {
    endCount += 1
  }
}
