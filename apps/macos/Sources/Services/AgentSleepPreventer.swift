import Foundation

@MainActor
final class AgentSleepPreventer {
  private let activityManager: any AgentSleepActivityManaging
  private var activity: NSObjectProtocol?

  init(activityManager: any AgentSleepActivityManaging = ProcessInfo.processInfo) {
    self.activityManager = activityManager
  }

  deinit {
    MainActor.assumeIsolated {
      if let activity {
        activityManager.endActivity(activity)
      }
    }
  }

  func setActive(_ isActive: Bool) {
    switch (isActive, activity) {
    case (true, nil):
      activity = activityManager.beginActivity(
        options: [.idleSystemSleepDisabled],
        reason: "Argon agents are running"
      )
    case (false, let activeActivity?):
      activityManager.endActivity(activeActivity)
      activity = nil
    default:
      break
    }
  }
}

protocol AgentSleepActivityManaging: AnyObject {
  func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol
  func endActivity(_ activity: NSObjectProtocol)
}

extension ProcessInfo: AgentSleepActivityManaging {}
