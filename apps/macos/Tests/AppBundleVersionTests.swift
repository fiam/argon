import Testing

@testable import Argon

@Suite("AppBundleVersion")
struct AppBundleVersionTests {
  @Test("display version prefers bundle short version")
  func displayVersionPrefersBundleShortVersion() {
    let version = AppBundleVersion.displayVersion(
      infoDictionary: [
        "CFBundleShortVersionString": " 0.2.0 ",
        "CFBundleVersion": "24",
      ]
    )

    #expect(version == "0.2.0")
  }

  @Test("display version falls back to build version")
  func displayVersionFallsBackToBuildVersion() {
    let version = AppBundleVersion.displayVersion(
      infoDictionary: [
        "CFBundleShortVersionString": " ",
        "CFBundleVersion": "24",
      ]
    )

    #expect(version == "24")
  }

  @Test("display version falls back to unknown")
  func displayVersionFallsBackToUnknown() {
    #expect(AppBundleVersion.displayVersion(infoDictionary: [:]) == "Unknown")
  }
}
