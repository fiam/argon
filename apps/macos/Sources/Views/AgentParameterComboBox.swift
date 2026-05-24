import AppKit
import SwiftUI

struct AgentParameterComboBox: NSViewRepresentable {
  @Binding var text: String
  let prompt: String
  let choices: [String]
  let isDisabled: Bool
  let isMonospaced: Bool
  let accessibilityLabel: String

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> NSComboBox {
    let comboBox = NSComboBox()
    comboBox.delegate = context.coordinator
    comboBox.isEditable = true
    comboBox.completes = true
    comboBox.hasVerticalScroller = true
    comboBox.usesDataSource = false
    comboBox.numberOfVisibleItems = min(max(choices.count, 4), 12)
    comboBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
    comboBox.setAccessibilityLabel(accessibilityLabel)
    return comboBox
  }

  func updateNSView(_ comboBox: NSComboBox, context: Context) {
    context.coordinator.parent = self
    context.coordinator.isUpdating = true

    if context.coordinator.choices != choices {
      context.coordinator.choices = choices
      comboBox.removeAllItems()
      comboBox.addItems(withObjectValues: choices)
      comboBox.numberOfVisibleItems = min(max(choices.count, 4), 12)
    }

    if comboBox.stringValue != text {
      comboBox.stringValue = text
    }
    comboBox.placeholderString = prompt
    comboBox.isEnabled = !isDisabled
    comboBox.font =
      isMonospaced
      ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      : NSFont.systemFont(ofSize: NSFont.systemFontSize)
    comboBox.setAccessibilityLabel(accessibilityLabel)

    context.coordinator.isUpdating = false
  }

  final class Coordinator: NSObject, NSComboBoxDelegate {
    var parent: AgentParameterComboBox
    var choices: [String] = []
    var isUpdating = false

    init(_ parent: AgentParameterComboBox) {
      self.parent = parent
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
      guard !isUpdating, let comboBox = notification.object as? NSComboBox else { return }
      parent.text = comboBox.stringValue
    }

    func controlTextDidChange(_ notification: Notification) {
      guard !isUpdating, let comboBox = notification.object as? NSComboBox else { return }
      parent.text = comboBox.stringValue
    }
  }
}
