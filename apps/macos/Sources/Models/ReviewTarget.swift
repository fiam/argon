import Foundation

struct ReviewTarget: Codable, Hashable, Sendable {
  let sessionId: String
  let repoRoot: String
}
