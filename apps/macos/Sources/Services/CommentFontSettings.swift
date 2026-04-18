import Foundation

enum CommentFontSettings {
  static let storageKey = "commentFontSize"
  static let defaultSize = 14.0
  static let range: ClosedRange<Double> = 11...24

  static func clamped(_ value: Double) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }
}
