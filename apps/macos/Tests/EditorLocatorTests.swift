import Foundation
import Testing

@testable import Argon

@Suite("EditorLocator")
struct EditorLocatorTests {

  @Test("discoverInstalledEditors keeps detection order and resolves names from detected apps")
  @MainActor
  func discoverInstalledEditorsKeepsDetectionOrderAndResolvesNamesFromDetectedApps() {
    let applications: [String: URL] = [
      "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
      "com.apple.dt.Xcode": URL(fileURLWithPath: "/Applications/Xcode.app"),
      "com.todesktop.230313mzl4w4u92": URL(fileURLWithPath: "/Applications/Cursor.app"),
    ]

    let displayNames: [URL: String] = [
      URL(fileURLWithPath: "/Applications/Visual Studio Code.app"): "Visual Studio Code",
      URL(fileURLWithPath: "/Applications/Xcode.app"): "Xcode",
      URL(fileURLWithPath: "/Applications/Cursor.app"): "Cursor",
    ]

    let editors = EditorLocator.discoverInstalledEditors(
      applicationURLForBundleID: { applications[$0] },
      displayNameForApplicationURL: { displayNames[$0] ?? $0.lastPathComponent }
    )

    #expect(editors.map(\.displayName) == ["Visual Studio Code", "Cursor", "Xcode"])
    #expect(
      editors.map(\.bundleIdentifier) == [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "com.apple.dt.Xcode",
      ])
  }
}
