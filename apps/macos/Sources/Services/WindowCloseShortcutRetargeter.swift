import AppKit

@MainActor
enum WindowCloseShortcutRetargeter {
  private static let closeWindowTitle = "Close Window"
  private static let closeWindowIconName = "rectangle.badge.xmark"
  private static var observers: [NSObjectProtocol] = []

  static func install() {
    guard observers.isEmpty else { return }

    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: NSMenu.didAddItemNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { @MainActor in
          retargetApplicationMenu()
        }
      },
      center.addObserver(
        forName: NSMenu.didChangeItemNotification,
        object: nil,
        queue: .main
      ) { _ in
        Task { @MainActor in
          retargetApplicationMenu()
        }
      },
    ]

    retargetApplicationMenu()
  }

  static func retargetApplicationMenu() {
    guard let mainMenu = NSApp.mainMenu else { return }
    retarget(menu: mainMenu)
  }

  static func retarget(menu: NSMenu) {
    for item in menu.items {
      if shouldRetarget(item) {
        retarget(item)
      }

      if let submenu = item.submenu {
        retarget(menu: submenu)
      }
    }
  }

  private static func retarget(_ item: NSMenuItem) {
    item.title = closeWindowTitle
    item.keyEquivalentModifierMask = [.command, .shift]
    item.image = NSImage(systemSymbolName: closeWindowIconName, accessibilityDescription: nil)
  }

  private static func shouldRetarget(_ item: NSMenuItem) -> Bool {
    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard title == "close" || title == "close window" else { return false }
    guard item.keyEquivalent.lowercased() == "w" else { return false }
    return item.keyEquivalentModifierMask.intersection([
      .command, .shift, .option, .control,
    ]) == .command
  }
}
