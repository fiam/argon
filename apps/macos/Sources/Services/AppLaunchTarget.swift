import Foundation

enum AppLaunchTarget {
  enum LaunchRequest: Equatable {
    case workspace(WorkspaceTarget)
    case review(ReviewTarget)
  }

  static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchRequest? {
    var sessionId: String?
    var repoRoot: String?
    var reviewLaunchContext: ReviewLaunchContext = .standalone
    var workspaceRepoRoot: String?
    var workspaceCommonDir: String?
    var selectedWorktreePath: String?
    var index = 1

    while index < arguments.count {
      switch arguments[index] {
      case "--session-id" where index + 1 < arguments.count:
        sessionId = arguments[index + 1]
        index += 2
      case "--repo-root" where index + 1 < arguments.count:
        repoRoot = arguments[index + 1]
        index += 2
      case "--review-launch-context" where index + 1 < arguments.count:
        reviewLaunchContext =
          ReviewLaunchContext(rawValue: arguments[index + 1]) ?? .standalone
        index += 2
      case "--workspace-repo-root" where index + 1 < arguments.count:
        workspaceRepoRoot = arguments[index + 1]
        index += 2
      case "--workspace-common-dir" where index + 1 < arguments.count:
        workspaceCommonDir = arguments[index + 1]
        index += 2
      case "--selected-worktree-path" where index + 1 < arguments.count:
        selectedWorktreePath = arguments[index + 1]
        index += 2
      default:
        index += 1
      }
    }

    if let sessionId, let repoRoot {
      return .review(
        ReviewTarget(
          sessionId: sessionId,
          repoRoot: repoRoot,
          launchContext: reviewLaunchContext
        ))
    }

    guard let workspaceRepoRoot, let workspaceCommonDir else { return nil }
    return .workspace(
      WorkspaceTarget(
        repoRoot: workspaceRepoRoot,
        repoCommonDir: workspaceCommonDir,
        selectedWorktreePath: selectedWorktreePath
      ))
  }

  static func request(from url: URL) -> LaunchRequest? {
    guard url.scheme == "argon" else { return nil }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }

    switch components.host {
    case "workspace":
      guard
        let repoRoot = components.queryValue(named: "repo-root"),
        let repoCommonDir = components.queryValue(named: "repo-common-dir")
      else {
        return nil
      }
      return .workspace(
        WorkspaceTarget(
          repoRoot: repoRoot,
          repoCommonDir: repoCommonDir,
          selectedWorktreePath: components.queryValue(named: "selected-worktree-path")
        ))
    case "review":
      guard
        let sessionId = components.queryValue(named: "session-id"),
        let repoRoot = components.queryValue(named: "repo-root")
      else {
        return nil
      }
      let launchContext =
        components.queryValue(named: "review-launch-context")
        .flatMap(ReviewLaunchContext.init(rawValue:)) ?? .standalone
      return .review(
        ReviewTarget(
          sessionId: sessionId,
          repoRoot: repoRoot,
          launchContext: launchContext
        ))
    default:
      return nil
    }
  }
}

extension URLComponents {
  fileprivate func queryValue(named name: String) -> String? {
    queryItems?.first { $0.name == name }?.value
  }
}
