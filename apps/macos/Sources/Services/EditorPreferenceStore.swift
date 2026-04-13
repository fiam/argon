import Foundation

enum EditorPreferenceStore {
  private static let key = "preferredEditorsByWorktreePath"

  static func preferredBundleIdentifier(
    for worktreePath: String,
    userDefaults: UserDefaults = .standard
  ) -> String? {
    loadPreferences(userDefaults: userDefaults)[normalizedPath(worktreePath)]
  }

  static func setPreferredBundleIdentifier(
    _ bundleIdentifier: String,
    for worktreePath: String,
    userDefaults: UserDefaults = .standard
  ) {
    var preferences = loadPreferences(userDefaults: userDefaults)
    preferences[normalizedPath(worktreePath)] = bundleIdentifier
    savePreferences(preferences, userDefaults: userDefaults)
  }

  static func preferredEditor(
    for worktreePath: String,
    among editors: [DetectedEditorApp],
    userDefaults: UserDefaults = .standard
  ) -> DetectedEditorApp? {
    guard !editors.isEmpty else { return nil }

    if let preferredBundleIdentifier = preferredBundleIdentifier(
      for: worktreePath,
      userDefaults: userDefaults
    ),
      let preferredEditor = editors.first(where: {
        $0.bundleIdentifier == preferredBundleIdentifier
      })
    {
      return preferredEditor
    }

    return editors.first
  }

  static func alternativeEditors(
    for worktreePath: String,
    among editors: [DetectedEditorApp],
    userDefaults: UserDefaults = .standard
  ) -> [DetectedEditorApp] {
    guard
      let preferredEditor = preferredEditor(
        for: worktreePath,
        among: editors,
        userDefaults: userDefaults
      )
    else {
      return editors
    }

    return editors.filter { $0.bundleIdentifier != preferredEditor.bundleIdentifier }
  }

  private static func loadPreferences(userDefaults: UserDefaults) -> [String: String] {
    guard let data = userDefaults.data(forKey: key),
      let preferences = try? JSONDecoder().decode([String: String].self, from: data)
    else {
      return [:]
    }

    return preferences
  }

  private static func savePreferences(
    _ preferences: [String: String],
    userDefaults: UserDefaults
  ) {
    guard let data = try? JSONEncoder().encode(preferences) else { return }
    userDefaults.set(data, forKey: key)
  }

  private static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
