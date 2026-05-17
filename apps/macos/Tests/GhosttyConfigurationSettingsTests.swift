import XCTest

@testable import Argon

final class GhosttyConfigurationSettingsTests: XCTestCase {
  private var temporaryDirectories: [URL] = []

  override func tearDownWithError() throws {
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    temporaryDirectories.removeAll()
    try super.tearDownWithError()
  }

  func testFontSizeReturnsNilForEmptyConfig() {
    XCTAssertNil(GhosttyConfigurationSettings.fontSize(from: ""))
    XCTAssertNil(GhosttyConfigurationSettings.fontSize(from: "   \n\n"))
  }

  func testFontSizeParsesConfiguredValue() throws {
    let config = """
      font-family = JetBrainsMono Nerd Font
      font-size = 13
      """
    let parsed = try XCTUnwrap(GhosttyConfigurationSettings.fontSize(from: config))
    XCTAssertEqual(parsed, 13, accuracy: 0.001)
  }

  func testFontSizeUsesLastValueAndIgnoresComments() throws {
    let config = """
      # font-size = 9
      font-size = 12
      font-size = 14 # inline comment
      """
    let parsed = try XCTUnwrap(GhosttyConfigurationSettings.fontSize(from: config))
    XCTAssertEqual(parsed, 14, accuracy: 0.001)
  }

  func testResolvedConfigTextPrefersXDGConfigOverGeneratedAppSupportTemplate() throws {
    let home = try makeTemporaryDirectory()
    let xdgConfig = home.appendingPathComponent(".config/ghostty/config")
    let appSupportConfig = home.appendingPathComponent(
      "Library/Application Support/com.mitchellh.ghostty/config"
    )
    try write("font-size = 15\n", to: xdgConfig)
    try write(Self.generatedTemplate, to: appSupportConfig)

    let resolved = try XCTUnwrap(
      GhosttyConfigurationSettings.resolvedConfigText(
        fileManager: .default,
        environment: [:],
        homeDirectory: home,
        ghosttyOpenPath: appSupportConfig.path
      )
    )

    XCTAssertEqual(resolved, "font-size = 15\n")
  }

  func testResolvedConfigTextKeepsRealAppSupportConfig() throws {
    let home = try makeTemporaryDirectory()
    let xdgConfig = home.appendingPathComponent(".config/ghostty/config")
    let appSupportConfig = home.appendingPathComponent(
      "Library/Application Support/com.mitchellh.ghostty/config"
    )
    try write("font-size = 15\n", to: xdgConfig)
    try write(Self.generatedTemplate + "\nfont-size = 16\n", to: appSupportConfig)

    let resolved = try XCTUnwrap(
      GhosttyConfigurationSettings.resolvedConfigText(
        fileManager: .default,
        environment: [:],
        homeDirectory: home,
        ghosttyOpenPath: appSupportConfig.path
      )
    )

    XCTAssertEqual(resolved, Self.generatedTemplate + "\nfont-size = 16\n")
  }

  func testResolvedConfigTextPrefersCurrentXDGNameOverLegacyName() throws {
    let home = try makeTemporaryDirectory()
    let legacyConfig = home.appendingPathComponent(".config/ghostty/config")
    let currentConfig = home.appendingPathComponent(".config/ghostty/config.ghostty")
    let appSupportConfig = home.appendingPathComponent(
      "Library/Application Support/com.mitchellh.ghostty/config"
    )
    try write("font-size = 14\n", to: legacyConfig)
    try write("font-size = 15\n", to: currentConfig)
    try write(Self.generatedTemplate, to: appSupportConfig)

    let resolved = try XCTUnwrap(
      GhosttyConfigurationSettings.resolvedConfigText(
        fileManager: .default,
        environment: [:],
        homeDirectory: home,
        ghosttyOpenPath: appSupportConfig.path
      )
    )

    XCTAssertEqual(resolved, "font-size = 15\n")
  }

  func testResolvedConfigTextUsesXDGConfigHomeEnvironment() throws {
    let home = try makeTemporaryDirectory()
    let xdgHome = try makeTemporaryDirectory()
    let xdgConfig = xdgHome.appendingPathComponent("ghostty/config")
    let appSupportConfig = home.appendingPathComponent(
      "Library/Application Support/com.mitchellh.ghostty/config"
    )
    try write("font-size = 15\n", to: xdgConfig)
    try write(Self.generatedTemplate, to: appSupportConfig)

    let resolved = try XCTUnwrap(
      GhosttyConfigurationSettings.resolvedConfigText(
        fileManager: .default,
        environment: ["XDG_CONFIG_HOME": xdgHome.path],
        homeDirectory: home,
        ghosttyOpenPath: appSupportConfig.path
      )
    )

    XCTAssertEqual(resolved, "font-size = 15\n")
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    temporaryDirectories.append(directory)
    return directory
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private static let generatedTemplate = """
    # This is the configuration file for Ghostty.
    #
    # This template file has been automatically created at the following
    # path since Ghostty couldn't find any existing config files on your system:
    #
    #   /Users/example/Library/Application Support/com.mitchellh.ghostty/config
    """
}
