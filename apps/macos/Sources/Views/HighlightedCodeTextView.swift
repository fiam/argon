import AppKit
import SwiftUI

struct HighlightedCodeTextView: NSViewRepresentable {
  @Binding var text: String
  var path: String
  var fontSize: CGFloat = NSFont.systemFontSize
  var theme: String
  var isEditable = true
  var accessibilityIdentifier: String? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  @MainActor
  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false

    let textView = NSTextView()
    textView.allowsUndo = true
    textView.isRichText = false
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.backgroundColor = NSColor.textBackgroundColor
    textView.textColor = NSColor.labelColor
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.autoresizingMask = [.width]
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.delegate = context.coordinator

    applyPlainText(to: textView, text: text)
    context.coordinator.scheduleHighlight(
      for: textView,
      text: text,
      theme: theme,
      path: path,
      immediate: true
    )

    scrollView.documentView = textView
    if let accessibilityIdentifier {
      scrollView.setAccessibilityIdentifier(accessibilityIdentifier)
      textView.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    return scrollView
  }

  @MainActor
  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    context.coordinator.parent = self
    textView.isEditable = isEditable
    if textView.string != text {
      applyPlainText(to: textView, text: text)
      context.coordinator.scheduleHighlight(
        for: textView, text: text, theme: theme, path: path, immediate: true)
    } else {
      context.coordinator.scheduleHighlight(for: textView, text: text, theme: theme, path: path)
    }
    if let accessibilityIdentifier {
      scrollView.setAccessibilityIdentifier(accessibilityIdentifier)
      textView.setAccessibilityIdentifier(accessibilityIdentifier)
    }
  }

  @MainActor
  private func applyPlainText(to textView: NSTextView, text: String) {
    let selectedRange = textView.selectedRange()
    let attributes = baseAttributes(fontSize: fontSize)
    textView.textStorage?.setAttributedString(
      NSAttributedString(string: text, attributes: attributes))
    textView.typingAttributes = attributes
    let clampedLocation = min(selectedRange.location, textView.string.utf16.count)
    let clampedLength = min(selectedRange.length, textView.string.utf16.count - clampedLocation)
    textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
  }

  private func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
    [
      .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
      .foregroundColor: NSColor.labelColor,
    ]
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: HighlightedCodeTextView
    private var highlightTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var lastHighlightedText = ""
    private var lastHighlightedTheme = ""
    private var lastHighlightedPath = ""

    init(_ parent: HighlightedCodeTextView) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      guard parent.isEditable else { return }
      let updatedText = textView.string
      parent.text = updatedText
      scheduleHighlight(for: textView, text: updatedText, theme: parent.theme, path: parent.path)
    }

    @MainActor
    func scheduleHighlight(
      for textView: NSTextView,
      text: String,
      theme: String,
      path: String,
      immediate: Bool = false
    ) {
      if text.isEmpty {
        highlightTask?.cancel()
        lastHighlightedText = ""
        lastHighlightedTheme = theme
        lastHighlightedPath = path
        return
      }
      if lastHighlightedText == text && lastHighlightedTheme == theme && lastHighlightedPath == path
      {
        return
      }

      revision &+= 1
      let currentRevision = revision
      highlightTask?.cancel()
      let fontSize = parent.fontSize

      highlightTask = Task {
        if !immediate {
          try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }

        let highlighted = try? await Task.detached(priority: .userInitiated) {
          try ArgonCLI.highlightedText(text: text, path: path, theme: theme)
        }.value

        await MainActor.run {
          guard !Task.isCancelled else { return }
          guard currentRevision == self.revision else { return }
          guard textView.string == text else { return }
          guard let highlighted else { return }
          self.applyHighlightedText(
            highlighted.lines, to: textView, originalText: text, fontSize: fontSize)
          self.lastHighlightedText = text
          self.lastHighlightedTheme = theme
          self.lastHighlightedPath = path
        }
      }
    }

    @MainActor
    private func applyHighlightedText(
      _ lines: [[StyledSpan]],
      to textView: NSTextView,
      originalText: String,
      fontSize: CGFloat
    ) {
      let attributed = NSMutableAttributedString()
      for (index, spans) in lines.enumerated() {
        if spans.isEmpty {
          attributed.append(
            NSAttributedString(
              string: "",
              attributes: parent.baseAttributes(fontSize: fontSize)
            ))
        } else {
          for span in spans {
            attributed.append(attributedSpan(from: span, fontSize: fontSize))
          }
        }
        if index < lines.count - 1 {
          attributed.append(
            NSAttributedString(
              string: "\n",
              attributes: parent.baseAttributes(fontSize: fontSize)
            ))
        }
      }

      guard attributed.string == originalText else { return }

      let selectedRange = textView.selectedRange()
      textView.textStorage?.setAttributedString(attributed)
      textView.typingAttributes = parent.baseAttributes(fontSize: fontSize)
      let clampedLocation = min(selectedRange.location, textView.string.utf16.count)
      let clampedLength = min(selectedRange.length, textView.string.utf16.count - clampedLocation)
      textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
    }

    private func attributedSpan(from span: StyledSpan, fontSize: CGFloat) -> NSAttributedString {
      let baseFont = NSFont.monospacedSystemFont(
        ofSize: fontSize, weight: span.bold ? .semibold : .regular)
      let descriptor =
        if span.italic {
          baseFont.fontDescriptor.withSymbolicTraits(.italic)
        } else {
          baseFont.fontDescriptor
        }
      let font = NSFont(descriptor: descriptor, size: fontSize) ?? baseFont

      var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.labelColor,
      ]
      if let fg = span.fg, let color = NSColor(hex: fg) {
        attributes[.foregroundColor] = color
      }
      return NSAttributedString(string: span.text, attributes: attributes)
    }
  }
}

extension NSColor {
  fileprivate convenience init?(hex: String) {
    var hexValue = hex
    if hexValue.hasPrefix("#") {
      hexValue = String(hexValue.dropFirst())
    }
    guard hexValue.count == 6, let value = UInt64(hexValue, radix: 16) else { return nil }
    self.init(
      red: CGFloat((value >> 16) & 0xFF) / 255.0,
      green: CGFloat((value >> 8) & 0xFF) / 255.0,
      blue: CGFloat(value & 0xFF) / 255.0,
      alpha: 1.0
    )
  }
}
