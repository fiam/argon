import AppKit
import Testing

@testable import Argon

@Suite("GhosttyAppShortcutPassthrough")
@MainActor
struct GhosttyAppShortcutPassthroughTests {
  private func makeMenu() -> NSMenu {
    let mainMenu = NSMenu(title: "Main")

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: "App")
    let settingsItem = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
    settingsItem.keyEquivalentModifierMask = [.command]
    appMenu.addItem(settingsItem)
    let quitItem = NSMenuItem(title: "Quit Argon", action: nil, keyEquivalent: "q")
    quitItem.keyEquivalentModifierMask = [.command]
    appMenu.addItem(quitItem)
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let fileMenuItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let newTab = NSMenuItem(title: "New Tab", action: nil, keyEquivalent: "t")
    newTab.keyEquivalentModifierMask = [.command]
    fileMenu.addItem(newTab)
    let newShell = NSMenuItem(title: "New Shell Tab", action: nil, keyEquivalent: "t")
    newShell.keyEquivalentModifierMask = [.command, .shift]
    fileMenu.addItem(newShell)
    let newPrivilegedShell = NSMenuItem(
      title: "New Privileged Shell Tab",
      action: nil,
      keyEquivalent: "t"
    )
    newPrivilegedShell.keyEquivalentModifierMask = [.command, .shift, .option]
    fileMenu.addItem(newPrivilegedShell)
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    return mainMenu
  }

  @Test("passes through settings shortcut")
  func passesThroughSettingsShortcut() {
    let menu = makeMenu()
    #expect(
      GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: ",",
        modifierFlags: [.command],
        menu: menu
      )
    )
  }

  @Test("passes through quit shortcut")
  func passesThroughQuitShortcut() {
    let menu = makeMenu()
    #expect(
      GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "q",
        modifierFlags: [.command],
        menu: menu
      )
    )
  }

  @Test("passes through supported new-tab shortcuts")
  func passesThroughNewTabShortcuts() {
    let menu = makeMenu()
    #expect(
      GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "t",
        modifierFlags: [.command],
        menu: menu
      )
    )
    #expect(
      GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "t",
        modifierFlags: [.command, .shift],
        menu: menu
      )
    )
    #expect(
      GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "t",
        modifierFlags: [.command, .shift, .option],
        menu: menu
      )
    )
  }

  @Test("does not pass through unsupported shortcuts")
  func doesNotPassThroughUnsupportedShortcuts() {
    let menu = makeMenu()
    #expect(
      !GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "r",
        modifierFlags: [.command],
        menu: menu
      )
    )
    #expect(
      !GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: ",",
        modifierFlags: [.command, .shift],
        menu: menu
      )
    )
    #expect(
      !GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: ",",
        modifierFlags: [.control],
        menu: menu
      )
    )
    #expect(
      !GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "q",
        modifierFlags: [.command, .shift],
        menu: menu
      )
    )
  }

  @Test("disabled menu items do not claim shortcuts")
  func disabledMenuItemsDoNotClaimShortcuts() {
    let menu = NSMenu(title: "Main")
    let item = NSMenuItem(title: "Disabled", action: nil, keyEquivalent: "w")
    item.keyEquivalentModifierMask = [.command]
    item.isEnabled = false
    menu.addItem(item)

    #expect(
      !GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "w",
        modifierFlags: [.command],
        menu: menu
      )
    )
  }
}
