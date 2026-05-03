import Foundation

enum AgentLaunchSettings {
  static let defaultYoloModeStorageKey = "defaultAgentLaunchYoloMode"
  static let defaultSandboxEnabledStorageKey = "defaultAgentLaunchSandboxEnabled"
  static let defaultYoloMode = true
  static let defaultSandboxEnabled = true

  static func isDefaultYoloModeEnabled(userDefaults: UserDefaults = .standard) -> Bool {
    guard userDefaults.object(forKey: defaultYoloModeStorageKey) != nil else {
      return defaultYoloMode
    }
    return userDefaults.bool(forKey: defaultYoloModeStorageKey)
  }

  static func setDefaultYoloModeEnabled(
    _ isEnabled: Bool,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(isEnabled, forKey: defaultYoloModeStorageKey)
  }

  static func isDefaultSandboxEnabled(userDefaults: UserDefaults = .standard) -> Bool {
    guard userDefaults.object(forKey: defaultSandboxEnabledStorageKey) != nil else {
      return defaultSandboxEnabled
    }
    return userDefaults.bool(forKey: defaultSandboxEnabledStorageKey)
  }

  static func setDefaultSandboxEnabled(
    _ isEnabled: Bool,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(isEnabled, forKey: defaultSandboxEnabledStorageKey)
  }
}
