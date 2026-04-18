import XCTest

@testable import Argon

final class GhosttyConfigurationSettingsTests: XCTestCase {
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
}
