import Foundation

struct AgentSessionRestoreMetadata: Codable, Equatable, Sendable {
  let familyID: AgentFamilyID
  let sessionID: String
  let cwd: String
  let yoloMode: Bool
  let sandboxEnabled: Bool
  let updatedAt: Date

  var key: String {
    Self.key(familyID: familyID, sessionID: sessionID, cwd: cwd)
  }

  static func key(familyID: AgentFamilyID, sessionID: String, cwd: String) -> String {
    "\(familyID.rawValue):\(sessionID):\(normalizedPath(cwd))"
  }

  private static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}

@MainActor
enum AgentSessionRestoreMetadataStore {
  static let storageKey = "agentSessionRestoreMetadata.v1"
  private static let maximumRecordCount = 300
  nonisolated(unsafe) static var userDefaults: UserDefaults = .standard

  static func metadata(
    familyID: AgentFamilyID,
    sessionID: String,
    cwd: String
  ) -> AgentSessionRestoreMetadata? {
    recordsByKey()[
      AgentSessionRestoreMetadata.key(
        familyID: familyID,
        sessionID: sessionID,
        cwd: cwd
      )]
  }

  static func record(_ metadata: AgentSessionRestoreMetadata) {
    var recordsByKey = recordsByKey()
    recordsByKey[metadata.key] = metadata

    let records =
      recordsByKey.values
      .sorted {
        if $0.updatedAt == $1.updatedAt {
          return $0.key < $1.key
        }
        return $0.updatedAt > $1.updatedAt
      }
      .prefix(maximumRecordCount)

    guard let data = try? JSONEncoder().encode(Array(records)) else { return }
    userDefaults.set(data, forKey: storageKey)
  }

  static func removeAll() {
    userDefaults.removeObject(forKey: storageKey)
  }

  private static func recordsByKey() -> [String: AgentSessionRestoreMetadata] {
    guard
      let data = userDefaults.data(forKey: storageKey),
      let records = try? JSONDecoder().decode([AgentSessionRestoreMetadata].self, from: data)
    else {
      return [:]
    }

    return records.reduce(into: [:]) { recordsByKey, metadata in
      recordsByKey[metadata.key] = metadata
    }
  }
}
