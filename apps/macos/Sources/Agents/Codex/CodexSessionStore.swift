import Foundation

enum CodexSessionStore {
  static func loadSessionRecords(notBefore: Date) -> [AgentResumeSessionRecord] {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }

    let keys: Set<URLResourceKey> = [.isRegularFileKey]
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
      guard fileURL.lastPathComponent.hasPrefix("rollout-") else { continue }
      guard
        let values = try? fileURL.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else {
        continue
      }
      guard
        let metadata = sessionMetadata(fromRolloutFilename: fileURL.lastPathComponent)
      else {
        continue
      }
      let startedAt = metadata.startedAt ?? .distantPast
      guard startedAt >= notBefore else { continue }
      guard let prefix = try? readUTF8Prefix(of: fileURL, maxBytes: 4096) else { continue }
      guard let cwd = cwd(inJSONLPrefix: prefix), !cwd.isEmpty else { continue }
      records.append(
        AgentResumeSessionRecord(
          familyID: .codex,
          sessionID: metadata.sessionID,
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

  private static func sessionMetadata(fromRolloutFilename filename: String)
    -> (sessionID: String, startedAt: Date?)?
  {
    guard filename.hasPrefix("rollout-"), filename.hasSuffix(".jsonl") else { return nil }
    let stem = filename.dropFirst("rollout-".count).dropLast(".jsonl".count)
    let timestampLength = 19  // yyyy-MM-dd'T'HH-mm-ss
    guard stem.count > timestampLength else {
      return nil
    }
    let separatorIndex = stem.index(stem.startIndex, offsetBy: timestampLength)
    guard stem[separatorIndex] == "-" else { return nil }

    let timestampText = String(stem[..<separatorIndex])
    let sessionStart = parseRolloutTimestamp(timestampText)

    let sessionIDStart = stem.index(after: separatorIndex)
    let sessionID = String(stem[sessionIDStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionID.isEmpty else {
      return nil
    }
    return (sessionID, sessionStart)
  }

  private static func parseRolloutTimestamp(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    return formatter.date(from: value)
  }

  private static func cwd(inJSONLPrefix text: String) -> String? {
    for line in text.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8) else { continue }
      guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }

      if let cwd = object["cwd"] as? String, !cwd.isEmpty {
        return cwd
      }

      if let item = object["item"] as? [String: Any],
        let cwd = item["cwd"] as? String,
        !cwd.isEmpty
      {
        return cwd
      }
    }

    return jsonStringValue(forKey: "cwd", in: text)
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
