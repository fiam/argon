import AppKit
import GhosttyKit
import Testing

@testable import Argon

@Suite("GhosttyInputBridge")
struct GhosttyInputBridgeTests {

  @Test("modifiers preserve right-side flags")
  func modifiersPreserveRightSideFlags() {
    let flags = NSEvent.ModifierFlags(
      rawValue:
        NSEvent.ModifierFlags.command.rawValue
        | NSEvent.ModifierFlags.option.rawValue
        | UInt(NX_DEVICERCMDKEYMASK)
        | UInt(NX_DEVICERALTKEYMASK)
    )

    let mods = GhosttyInputBridge.modifiers(from: flags)

    #expect(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    #expect(mods.rawValue & GHOSTTY_MODS_SUPER_RIGHT.rawValue != 0)
    #expect(mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
    #expect(mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue != 0)
  }

  @Test("event modifier flags decode ghostty mods")
  func eventModifierFlagsDecodeGhosttyMods() {
    let mods = ghostty_input_mods_e(
      GHOSTTY_MODS_SHIFT.rawValue
        | GHOSTTY_MODS_CTRL.rawValue
        | GHOSTTY_MODS_CAPS.rawValue
    )

    let flags = GhosttyInputBridge.eventModifierFlags(from: mods)

    #expect(flags.contains(.shift))
    #expect(flags.contains(.control))
    #expect(flags.contains(.capsLock))
    #expect(!flags.contains(.command))
  }

  @Test("mouse button mapping matches ghostty ordering")
  func mouseButtonMappingMatchesGhosttyOrdering() {
    #expect(GhosttyInputBridge.mouseButton(from: 0) == GHOSTTY_MOUSE_LEFT)
    #expect(GhosttyInputBridge.mouseButton(from: 1) == GHOSTTY_MOUSE_RIGHT)
    #expect(GhosttyInputBridge.mouseButton(from: 2) == GHOSTTY_MOUSE_MIDDLE)
    #expect(GhosttyInputBridge.mouseButton(from: 99) == GHOSTTY_MOUSE_UNKNOWN)
  }

  @Test("scroll mods pack precision and momentum")
  func scrollModsPackPrecisionAndMomentum() {
    let mods = GhosttyInputBridge.scrollMods(precision: true, momentumPhase: .ended)

    #expect(mods & 0b1 == 0b1)
    #expect((mods >> 1) == Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue))
  }

  @MainActor
  @Test("text for key event drops function-key private use characters")
  func textForKeyEventDropsFunctionKeyPrivateUseCharacters() throws {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{F704}",
        charactersIgnoringModifiers: "\u{F704}",
        isARepeat: false,
        keyCode: 126
      )
    )

    #expect(GhosttyInputBridge.textForKeyEvent(from: event) == nil)
  }

  @MainActor
  @Test("text for key event preserves printable text")
  func textForKeyEventPreservesPrintableText() throws {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "a",
        charactersIgnoringModifiers: "a",
        isARepeat: false,
        keyCode: 0
      )
    )

    #expect(GhosttyInputBridge.textForKeyEvent(from: event) == "a")
  }
}
