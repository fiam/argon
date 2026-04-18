import XCTest

@testable import Argon

final class CommentFontSettingsTests: XCTestCase {
  func testClampedReturnsLowerBoundForSmallValues() {
    XCTAssertEqual(CommentFontSettings.clamped(2), CommentFontSettings.range.lowerBound)
  }

  func testClampedReturnsUpperBoundForLargeValues() {
    XCTAssertEqual(CommentFontSettings.clamped(100), CommentFontSettings.range.upperBound)
  }

  func testClampedKeepsValuesWithinRange() {
    XCTAssertEqual(CommentFontSettings.clamped(14), 14, accuracy: 0.001)
  }
}
