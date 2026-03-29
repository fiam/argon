import SwiftUI

/// Animates a number change with an airport departure board-style rolling effect.
/// Each digit rolls independently from old value to new value.
struct RollingNumber: View {
  let value: Int
  let prefix: String
  let color: Color
  let font: Font

  init(_ value: Int, prefix: String = "", color: Color = .primary, font: Font = .caption) {
    self.value = value
    self.prefix = prefix
    self.color = color
    self.font = font
  }

  var body: some View {
    HStack(spacing: 0) {
      if !prefix.isEmpty {
        Text(prefix)
          .font(font)
          .fontWeight(.medium)
          .foregroundStyle(color)
      }
      ForEach(Array(digits.enumerated()), id: \.offset) { _, digit in
        RollingDigit(digit: digit, font: font, color: color)
      }
    }
  }

  private var digits: [Int] {
    let abs = abs(value)
    if abs == 0 { return [0] }
    var result: [Int] = []
    var n = abs
    while n > 0 {
      result.insert(n % 10, at: 0)
      n /= 10
    }
    return result
  }
}

struct RollingDigit: View {
  let digit: Int
  let font: Font
  let color: Color

  var body: some View {
    Text("\(digit)")
      .font(font)
      .fontWeight(.medium)
      .foregroundStyle(color)
      .contentTransition(.numericText(value: Double(digit)))
      .animation(.spring(duration: 0.4, bounce: 0.15), value: digit)
  }
}
