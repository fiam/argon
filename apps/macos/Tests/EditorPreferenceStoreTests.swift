import Foundation
import Testing

@testable import Argon

@Suite("EditorPreferenceStore")
struct EditorPreferenceStoreTests {

  @Test("preferred editor falls back to the first detected app when there is no saved choice")
  func preferredEditorFallsBackToFirstDetectedApp() {
    let defaults = makeUserDefaults()
    let editors = [
      DetectedEditorApp(
        bundleIdentifier: "com.microsoft.VSCode",
        displayName: "Visual Studio Code",
        applicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
      ),
      DetectedEditorApp(
        bundleIdentifier: "com.apple.dt.Xcode",
        displayName: "Xcode",
        applicationURL: URL(fileURLWithPath: "/Applications/Xcode.app")
      ),
    ]

    let preferredEditor = EditorPreferenceStore.preferredEditor(
      for: "/tmp/repo",
      among: editors,
      userDefaults: defaults
    )

    #expect(preferredEditor?.bundleIdentifier == "com.microsoft.VSCode")
  }

  @Test("preferred editor is stored per normalized worktree path")
  func preferredEditorIsStoredPerNormalizedWorktreePath() {
    let defaults = makeUserDefaults()

    EditorPreferenceStore.setPreferredBundleIdentifier(
      "com.apple.dt.Xcode",
      for: "/tmp/work/../work/repo",
      userDefaults: defaults
    )

    #expect(
      EditorPreferenceStore.preferredBundleIdentifier(
        for: "/tmp/work/repo",
        userDefaults: defaults
      ) == "com.apple.dt.Xcode"
    )
    #expect(
      EditorPreferenceStore.preferredBundleIdentifier(
        for: "/tmp/other-repo",
        userDefaults: defaults
      ) == nil
    )
  }

  @Test("preferred editor uses the saved choice when that editor is available")
  func preferredEditorUsesSavedChoiceWhenAvailable() {
    let defaults = makeUserDefaults()
    let editors = [
      DetectedEditorApp(
        bundleIdentifier: "com.microsoft.VSCode",
        displayName: "Visual Studio Code",
        applicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
      ),
      DetectedEditorApp(
        bundleIdentifier: "com.apple.dt.Xcode",
        displayName: "Xcode",
        applicationURL: URL(fileURLWithPath: "/Applications/Xcode.app")
      ),
    ]

    EditorPreferenceStore.setPreferredBundleIdentifier(
      "com.apple.dt.Xcode",
      for: "/tmp/repo",
      userDefaults: defaults
    )

    let preferredEditor = EditorPreferenceStore.preferredEditor(
      for: "/tmp/repo",
      among: editors,
      userDefaults: defaults
    )

    #expect(preferredEditor?.bundleIdentifier == "com.apple.dt.Xcode")
  }

  @Test("alternative editors exclude the current preferred editor")
  func alternativeEditorsExcludeCurrentPreferredEditor() {
    let defaults = makeUserDefaults()
    let editors = [
      DetectedEditorApp(
        bundleIdentifier: "com.microsoft.VSCode",
        displayName: "Visual Studio Code",
        applicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
      ),
      DetectedEditorApp(
        bundleIdentifier: "com.apple.dt.Xcode",
        displayName: "Xcode",
        applicationURL: URL(fileURLWithPath: "/Applications/Xcode.app")
      ),
      DetectedEditorApp(
        bundleIdentifier: "com.todesktop.230313mzl4w4u92",
        displayName: "Cursor",
        applicationURL: URL(fileURLWithPath: "/Applications/Cursor.app")
      ),
    ]

    EditorPreferenceStore.setPreferredBundleIdentifier(
      "com.apple.dt.Xcode",
      for: "/tmp/repo",
      userDefaults: defaults
    )

    let alternatives = EditorPreferenceStore.alternativeEditors(
      for: "/tmp/repo",
      among: editors,
      userDefaults: defaults
    )

    #expect(
      alternatives.map(\.bundleIdentifier) == [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
      ])
  }

  private func makeUserDefaults() -> UserDefaults {
    let suiteName = "EditorPreferenceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
