import AppKit
import Testing

@testable import Argon

@Suite("WindowCloseShortcutRetargeter")
@MainActor
struct WindowCloseShortcutRetargeterTests {
  @Test("moves default close window shortcut to command shift w")
  func movesDefaultCloseWindowShortcutToCommandShiftW() {
    let menu = NSMenu(title: "Main")
    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    let closeItem = NSMenuItem(title: "Close", action: nil, keyEquivalent: "w")
    closeItem.keyEquivalentModifierMask = [.command]
    windowMenu.addItem(closeItem)
    windowMenuItem.submenu = windowMenu
    menu.addItem(windowMenuItem)

    WindowCloseShortcutRetargeter.retarget(menu: menu)

    #expect(closeItem.title == "Close Window")
    #expect(closeItem.keyEquivalent == "w")
    #expect(
      closeItem.keyEquivalentModifierMask.intersection([.command, .shift]) == [
        .command, .shift,
      ])
    #expect(closeItem.image != nil)
  }

  @Test("keeps close tab on command w")
  func keepsCloseTabOnCommandW() {
    let menu = NSMenu(title: "Main")
    let fileMenuItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let closeTabItem = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "w")
    closeTabItem.keyEquivalentModifierMask = [.command]
    fileMenu.addItem(closeTabItem)
    fileMenuItem.submenu = fileMenu
    menu.addItem(fileMenuItem)

    WindowCloseShortcutRetargeter.retarget(menu: menu)

    #expect(closeTabItem.keyEquivalentModifierMask.intersection([.command, .shift]) == .command)
  }
}
