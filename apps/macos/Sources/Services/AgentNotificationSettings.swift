import Foundation

enum AgentNotificationSettings {
  static let enabledStorageKey = "agentNotificationsEnabled"
  static let suppressSystemDeniedLaunchWarningStorageKey =
    "agentNotificationsSuppressSystemDeniedLaunchWarning"
  static let defaultEnabled = true

  static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
    guard userDefaults.object(forKey: enabledStorageKey) != nil else {
      return defaultEnabled
    }

    return userDefaults.bool(forKey: enabledStorageKey)
  }

  static func setEnabled(_ isEnabled: Bool, userDefaults: UserDefaults = .standard) {
    userDefaults.set(isEnabled, forKey: enabledStorageKey)
  }

  static func shouldShowSystemDeniedLaunchWarning(userDefaults: UserDefaults = .standard) -> Bool {
    !userDefaults.bool(forKey: suppressSystemDeniedLaunchWarningStorageKey)
  }

  static func setSuppressSystemDeniedLaunchWarning(
    _ isSuppressed: Bool,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(isSuppressed, forKey: suppressSystemDeniedLaunchWarningStorageKey)
  }
}
