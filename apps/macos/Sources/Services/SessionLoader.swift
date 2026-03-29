import Foundation

enum SessionLoader {
  static func loadSession(sessionId: String, repoRoot: String) throws -> ReviewSession {
    let storageRoot = argonStorageRoot()
    let repoKey = Self.repoStorageKey(repoRoot: repoRoot)
    let sessionsDir =
      storageRoot
      .appendingPathComponent("sessions")
      .appendingPathComponent(repoKey)
    let sessionFile = sessionsDir.appendingPathComponent("\(sessionId).json")

    let data = try Data(contentsOf: sessionFile)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      if let date = ISO8601DateFormatter().date(from: string) {
        return date
      }
      // Try with fractional seconds
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions.insert(.withFractionalSeconds)
      if let date = formatter.date(from: string) {
        return date
      }
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid date: \(string)")
      )
    }
    return try decoder.decode(ReviewSession.self, from: data)
  }

  static func loadDraftReview(sessionId: String, repoRoot: String) throws -> [DraftComment] {
    let storageRoot = argonStorageRoot()
    let repoKey = Self.repoStorageKey(repoRoot: repoRoot)
    let draftFile =
      storageRoot
      .appendingPathComponent("sessions")
      .appendingPathComponent(repoKey)
      .appendingPathComponent("drafts")
      .appendingPathComponent("\(sessionId).json")

    guard FileManager.default.fileExists(atPath: draftFile.path) else {
      return []
    }

    let data = try Data(contentsOf: draftFile)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      if let date = ISO8601DateFormatter().date(from: string) {
        return date
      }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions.insert(.withFractionalSeconds)
      if let date = formatter.date(from: string) {
        return date
      }
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid date: \(string)")
      )
    }
    let draft = try decoder.decode(DraftReviewData.self, from: data)
    return draft.comments
  }

  private static func argonStorageRoot() -> URL {
    if let home = ProcessInfo.processInfo.environment["ARGON_HOME"], !home.isEmpty {
      return URL(fileURLWithPath: home)
    }
    if let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg).appendingPathComponent("argon")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".cache/argon")
  }

  private static func repoStorageKey(repoRoot: String) -> String {
    let url = URL(fileURLWithPath: repoRoot)
    let resolved = url.standardizedFileURL.path
    let name = URL(fileURLWithPath: resolved).lastPathComponent
    let sanitized = sanitizeRepoName(name)
    let repoName = sanitized.isEmpty ? "repo" : sanitized
    let hash = fnv1a64(Array(resolved.utf8))
    return "\(repoName)-\(String(format: "%016llx", hash))"
  }

  private static func sanitizeRepoName(_ name: String) -> String {
    String(
      name.compactMap { ch -> Character? in
        let lower = ch.lowercased().first!
        if lower.isASCII && (lower.isLetter || lower.isNumber || lower == "-" || lower == "_") {
          return lower
        }
        return nil
      })
  }

  private static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return hash
  }
}
