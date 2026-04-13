import Foundation

enum SessionLoader {
  /// Returns the sessions directory path for the given repo, for use with FileWatcher.
  static func sessionsDirectory(repoRoot: String) -> String {
    sessionsDirectoryURL(repoRoot: repoRoot).path
  }

  static func loadSession(sessionId: String, repoRoot: String) throws -> ReviewSession {
    let sessionFile = sessionsDirectoryURL(repoRoot: repoRoot)
      .appendingPathComponent("\(sessionId).json")

    let data = try Data(contentsOf: sessionFile)
    return try makeDecoder().decode(ReviewSession.self, from: data)
  }

  static func latestReviewSnapshots(forRepoRoots repoRoots: Set<String>)
    -> [String: WorkspaceReviewSnapshot]
  {
    let normalizedRepoRoots = Set(repoRoots.map(normalizePath))
    guard !normalizedRepoRoots.isEmpty else { return [:] }

    let sessionsRoot = argonStorageRoot().appendingPathComponent("sessions")
    guard
      let repoDirectories = try? FileManager.default.contentsOfDirectory(
        at: sessionsRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return [:]
    }

    var latestSessionsByRepoRoot: [String: ReviewSession] = [:]
    let decoder = makeDecoder()

    for repoDirectory in repoDirectories {
      guard (try? repoDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      else {
        continue
      }

      guard
        let sessionFiles = try? FileManager.default.contentsOfDirectory(
          at: repoDirectory,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }

      for sessionFile in sessionFiles where sessionFile.pathExtension == "json" {
        guard
          (try? sessionFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          let data = try? Data(contentsOf: sessionFile),
          let session = try? decoder.decode(ReviewSession.self, from: data)
        else {
          continue
        }

        let normalizedRepoRoot = normalizePath(session.repoRoot)
        guard normalizedRepoRoots.contains(normalizedRepoRoot) else { continue }

        if let current = latestSessionsByRepoRoot[normalizedRepoRoot],
          current.updatedAt >= session.updatedAt
        {
          continue
        }

        latestSessionsByRepoRoot[normalizedRepoRoot] = session
      }
    }

    return latestSessionsByRepoRoot.mapValues(WorkspaceReviewSnapshot.init(session:))
  }

  static func loadDraftReview(sessionId: String, repoRoot: String) throws -> [DraftComment] {
    let draftFile = sessionsDirectoryURL(repoRoot: repoRoot)
      .appendingPathComponent("drafts")
      .appendingPathComponent("\(sessionId).json")

    guard FileManager.default.fileExists(atPath: draftFile.path) else {
      return []
    }

    let data = try Data(contentsOf: draftFile)
    let draft = try makeDecoder().decode(DraftReviewData.self, from: data)
    return draft.comments
  }

  private static func makeDecoder() -> JSONDecoder {
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
    return decoder
  }

  private static func sessionsDirectoryURL(repoRoot: String) -> URL {
    let storageRoot = argonStorageRoot()
    let repoKey = repoStorageKey(repoRoot: repoRoot)
    return
      storageRoot
      .appendingPathComponent("sessions")
      .appendingPathComponent(repoKey)
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

  private static func normalizePath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
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
