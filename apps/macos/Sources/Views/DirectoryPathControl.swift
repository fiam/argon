import AppKit
import SwiftUI

struct DirectoryPathControl: NSViewRepresentable {
  let path: String
  let placeholder: String
  let onChoose: () -> Void

  init(
    path: String,
    placeholder: String = "Choose destination",
    onChoose: @escaping () -> Void
  ) {
    self.path = path
    self.placeholder = placeholder
    self.onChoose = onChoose
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onChoose: onChoose, placeholder: placeholder)
  }

  func makeNSView(context: Context) -> NSPathControl {
    let control = NSPathControl()
    control.pathStyle = .popUp
    control.controlSize = .small
    control.focusRingType = .none
    control.backgroundColor = .clear
    control.target = context.coordinator
    control.action = #selector(Coordinator.chooseDirectory)
    return control
  }

  func updateNSView(_ control: NSPathControl, context: Context) {
    context.coordinator.placeholder = placeholder
    control.pathItems = [context.coordinator.item(for: path)]
  }

  final class Coordinator: NSObject {
    private let onChoose: () -> Void
    var placeholder: String

    init(onChoose: @escaping () -> Void, placeholder: String) {
      self.onChoose = onChoose
      self.placeholder = placeholder
    }

    @objc func chooseDirectory() {
      onChoose()
    }

    func item(for path: String) -> NSPathControlItem {
      let item = NSPathControlItem()
      let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)

      if trimmedPath.isEmpty {
        item.title = placeholder
      } else {
        let url = URL(fileURLWithPath: trimmedPath, isDirectory: true)
        let name = url.lastPathComponent
        item.title = name.isEmpty ? trimmedPath : name
      }

      item.image = NSWorkspace.shared.icon(for: .folder)
      return item
    }
  }
}
