import Foundation

enum AgentSelectionSettings {
  static let rememberLastSelectionStorageKey = "rememberLastAgentSelection"
  static let lastSelectedAgentIDStorageKey = "lastSelectedAgentID"
  static let defaultRememberLastSelection = true

  static func rememberLastSelection(userDefaults: UserDefaults = .standard) -> Bool {
    guard userDefaults.object(forKey: rememberLastSelectionStorageKey) != nil else {
      return defaultRememberLastSelection
    }
    return userDefaults.bool(forKey: rememberLastSelectionStorageKey)
  }

  static func setRememberLastSelection(
    _ isEnabled: Bool,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(isEnabled, forKey: rememberLastSelectionStorageKey)
  }

  static func lastSelectedAgentID(userDefaults: UserDefaults = .standard) -> String? {
    let id = userDefaults.string(forKey: lastSelectedAgentIDStorageKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let id, !id.isEmpty else { return nil }
    return id
  }

  static func recordLastSelectedAgentID(
    _ id: String,
    userDefaults: UserDefaults = .standard
  ) {
    guard rememberLastSelection(userDefaults: userDefaults) else { return }
    userDefaults.set(id, forKey: lastSelectedAgentIDStorageKey)
  }

  static func preferredProfileID(
    in profiles: [SavedAgentProfile],
    userDefaults: UserDefaults = .standard,
    isSelectable: (SavedAgentProfile) -> Bool
  ) -> String? {
    guard rememberLastSelection(userDefaults: userDefaults),
      let rememberedID = lastSelectedAgentID(userDefaults: userDefaults)
    else { return nil }

    return profiles.first { profile in
      profile.id == rememberedID && isSelectable(profile)
    }?.id
  }
}
