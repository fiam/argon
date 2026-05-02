import Foundation

enum ClaudeCodeSessionStore {
  static func loadSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord] {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/projects", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }

    let keys: Set<URLResourceKey> = [
      .creationDateKey, .contentModificationDateKey, .isRegularFileKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    var records: [AgentResumeSessionRecord] = []
    for case let fileURL as URL in enumerator {
      guard fileURL.pathExtension == "jsonl" else { continue }
      guard
        let values = try? fileURL.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else {
        continue
      }

      let prefix = (try? readUTF8Prefix(of: fileURL, maxBytes: 16 * 1024)) ?? ""
      let sessionID =
        jsonStringValue(forKeys: ["sessionId", "session_id"], inJSONLPrefix: prefix)
        ?? fileURL.deletingPathExtension().lastPathComponent
      guard !sessionID.isEmpty else { continue }

      let startedAt =
        jsonDateValue(forKeys: ["timestamp", "createdAt", "startTime"], inJSONLPrefix: prefix)
        ?? values.creationDate
        ?? values.contentModificationDate
        ?? .distantPast
      guard startedAt >= notBefore else { continue }

      let projectDirectory = fileURL.deletingLastPathComponent()
      guard
        let cwd =
          jsonStringValue(forKeys: ["cwd", "projectRoot"], inJSONLPrefix: prefix)
          ?? cwdFromProjectDirectory(projectDirectory),
        !cwd.isEmpty
      else { continue }

      records.append(
        AgentResumeSessionRecord(
          familyID: .claudeCode,
          sessionID: sessionID,
          cwd: cwd,
          startedAt: startedAt
        )
      )
    }

    return records
  }

  private static func readUTF8Prefix(of url: URL, maxBytes: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  private static func cwdFromProjectDirectory(_ url: URL) -> String? {
    let name = url.lastPathComponent
    guard name.hasPrefix("-") else { return nil }
    let path = "/" + String(name.dropFirst()).replacingOccurrences(of: "-", with: "/")
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private static func jsonStringValue(forKeys keys: [String], inJSONLPrefix text: String) -> String?
  {
    for line in text.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8) else { continue }
      guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }

      for key in keys {
        if let value = object[key] as? String, !value.isEmpty {
          return value
        }
      }
    }

    for key in keys {
      if let value = jsonStringValue(forKey: key, in: text), !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private static func jsonDateValue(forKeys keys: [String], inJSONLPrefix text: String) -> Date? {
    guard let value = jsonStringValue(forKeys: keys, inJSONLPrefix: text) else { return nil }
    return iso8601Date(from: value)
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

  private static func jsonStringValue(forKey key: String, in text: String) -> String? {
    let token = "\"\(key)\":\""
    guard let tokenRange = text.range(of: token) else { return nil }
    var index = tokenRange.upperBound
    var escaped = false
    var characters: [Character] = []

    while index < text.endIndex {
      let character = text[index]
      if escaped {
        characters.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        let raw = String(characters)
        return raw.replacingOccurrences(of: "\\/", with: "/")
      } else {
        characters.append(character)
      }
      index = text.index(after: index)
    }

    return nil
  }
}
