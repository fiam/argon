import AppKit
import Testing

@testable import Argon

@Suite("GhosttyAppShortcutPassthrough")
struct GhosttyAppShortcutPassthroughTests {

  @Test("passes through settings shortcut")
  func passesThroughSettingsShortcut() {
    #expect(
      GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: ",",
        modifierFlags: [.command]
      )
    )
  }

  @Test("passes through supported new-tab shortcuts")
  func passesThroughNewTabShortcuts() {
    #expect(
      GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "t",
        modifierFlags: [.command]
      )
    )
    #expect(
      GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "t",
        modifierFlags: [.command, .shift]
      )
    )
    #expect(
      GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "t",
        modifierFlags: [.command, .shift, .option]
      )
    )
  }

  @Test("does not pass through unsupported shortcuts")
  func doesNotPassThroughUnsupportedShortcuts() {
    #expect(
      !GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: "r",
        modifierFlags: [.command]
      )
    )
    #expect(
      !GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: ",",
        modifierFlags: [.command, .shift]
      )
    )
    #expect(
      !GhosttyAppShortcutPassthrough.shouldPassThrough(
        charactersIgnoringModifiers: ",",
        modifierFlags: [.control]
      )
    )
  }
}
