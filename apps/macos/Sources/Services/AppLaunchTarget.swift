import Foundation

enum AppLaunchTarget {
  static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> ReviewTarget? {
    var sessionId: String?
    var repoRoot: String?
    var index = 1

    while index < arguments.count {
      switch arguments[index] {
      case "--session-id" where index + 1 < arguments.count:
        sessionId = arguments[index + 1]
        index += 2
      case "--repo-root" where index + 1 < arguments.count:
        repoRoot = arguments[index + 1]
        index += 2
      default:
        index += 1
      }
    }

    guard let sessionId, let repoRoot else { return nil }
    return ReviewTarget(sessionId: sessionId, repoRoot: repoRoot)
  }
}
