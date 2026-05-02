import Foundation

enum GeminiSessionStore {
  static func loadSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord] {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".gemini", isDirectory: true)
    let candidateRoots = [
      root.appendingPathComponent("tmp", isDirectory: true),
      root.appendingPathComponent("history", isDirectory: true),
    ]

    var recordsByKey: [String: AgentResumeSessionRecord] = [:]
    for candidateRoot in candidateRoots {
      guard
        let projectDirectories = try? FileManager.default.contentsOfDirectory(
          at: candidateRoot,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      else { continue }

      for projectDirectory in projectDirectories {
        guard isDirectory(projectDirectory) else { continue }
        guard let cwd = projectRoot(in: projectDirectory) else { continue }
        let chatsDirectory = projectDirectory.appendingPathComponent("chats", isDirectory: true)
        guard
          let chatFiles = try? FileManager.default.contentsOfDirectory(
            at: chatsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          )
        else { continue }

        for chatFile in chatFiles where chatFile.pathExtension == "json" {
          guard isRegularFile(chatFile) else { continue }
          guard let record = sessionRecord(from: chatFile, cwd: cwd) else { continue }
          guard record.startedAt >= notBefore else { continue }

          let key = "\(record.cwd):\(record.sessionID)"
          if let existing = recordsByKey[key], existing.startedAt >= record.startedAt {
            continue
          }
          recordsByKey[key] = record
        }
      }
    }

    return Array(recordsByKey.values)
  }

  private static func sessionRecord(from fileURL: URL, cwd: String) -> AgentResumeSessionRecord? {
    guard
      let data = try? Data(contentsOf: fileURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    guard let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else {
      return nil
    }

    let startedAt =
      (object["startTime"] as? String).flatMap(iso8601Date)
      ?? (object["lastUpdated"] as? String).flatMap(iso8601Date)
      ?? sessionStartDate(fromFilename: fileURL.lastPathComponent)
      ?? .distantPast

    return AgentResumeSessionRecord(
      familyID: .gemini,
      sessionID: sessionID,
      cwd: cwd,
      startedAt: startedAt
    )
  }

  private static func projectRoot(in projectDirectory: URL) -> String? {
    let rootFile = projectDirectory.appendingPathComponent(".project_root")
    guard let contents = try? String(contentsOf: rootFile, encoding: .utf8) else { return nil }
    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.path
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }

  private static func sessionStartDate(fromFilename filename: String) -> Date? {
    guard filename.hasPrefix("session-"), filename.hasSuffix(".json") else { return nil }
    let stem = filename.dropFirst("session-".count).dropLast(".json".count)
    let timestampLength = 16  // yyyy-MM-dd'T'HH-mm
    guard stem.count >= timestampLength else { return nil }
    let timestampEnd = stem.index(stem.startIndex, offsetBy: timestampLength)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm"
    return formatter.date(from: String(stem[..<timestampEnd]))
  }

  private static func iso8601Date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
