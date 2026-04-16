import Foundation

enum ReviewLaunchContext: String, Codable, Hashable, Sendable {
  case standalone
  case coderHandoff
}

struct ReviewTarget: Codable, Hashable, Sendable {
  let sessionId: String
  let repoRoot: String
  let launchContext: ReviewLaunchContext

  init(sessionId: String, repoRoot: String) {
    self.sessionId = sessionId
    self.repoRoot = repoRoot
    self.launchContext = .standalone
  }

  init(
    sessionId: String,
    repoRoot: String,
    launchContext: ReviewLaunchContext
  ) {
    self.sessionId = sessionId
    self.repoRoot = repoRoot
    self.launchContext = launchContext
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case repoRoot
    case launchContext
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    repoRoot = try container.decode(String.self, forKey: .repoRoot)
    launchContext =
      try container.decodeIfPresent(ReviewLaunchContext.self, forKey: .launchContext)
      ?? .standalone
  }
}
