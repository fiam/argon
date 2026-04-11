import AppKit
import GhosttyKit

enum GhosttyInputBridge {
  static func eventModifierFlags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    if mods.rawValue & GHOSTTY_MODS_CAPS.rawValue != 0 { flags.insert(.capsLock) }
    return flags
  }

  static func modifiers(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue

    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

    let rawFlags = flags.rawValue
    if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(mods)
  }

  static func keyEvent(
    from event: NSEvent,
    action: ghostty_input_action_e,
    translationModifiers: NSEvent.ModifierFlags? = nil,
    composing: Bool = false
  ) -> ghostty_input_key_s {
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.text = nil
    keyEvent.composing = composing
    keyEvent.mods = modifiers(from: event.modifierFlags)
    keyEvent.consumed_mods = modifiers(
      from: (translationModifiers ?? event.modifierFlags).subtracting([.control, .command])
    )
    keyEvent.unshifted_codepoint = 0

    if event.type == .keyDown || event.type == .keyUp,
      let chars = event.characters(byApplyingModifiers: []),
      let codepoint = chars.unicodeScalars.first
    {
      keyEvent.unshifted_codepoint = codepoint.value
    }

    return keyEvent
  }

  static func textForKeyEvent(from event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }

    if characters.count == 1, let scalar = characters.unicodeScalars.first {
      if scalar.value < 0x20 {
        return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
      }

      if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
        return nil
      }
    }

    return characters
  }

  static func mouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
    switch buttonNumber {
    case 0: GHOSTTY_MOUSE_LEFT
    case 1: GHOSTTY_MOUSE_RIGHT
    case 2: GHOSTTY_MOUSE_MIDDLE
    case 3: GHOSTTY_MOUSE_EIGHT
    case 4: GHOSTTY_MOUSE_NINE
    case 5: GHOSTTY_MOUSE_SIX
    case 6: GHOSTTY_MOUSE_SEVEN
    case 7: GHOSTTY_MOUSE_FOUR
    case 8: GHOSTTY_MOUSE_FIVE
    case 9: GHOSTTY_MOUSE_TEN
    case 10: GHOSTTY_MOUSE_ELEVEN
    default: GHOSTTY_MOUSE_UNKNOWN
    }
  }

  static func scrollMods(
    precision: Bool,
    momentumPhase: NSEvent.Phase
  ) -> ghostty_input_scroll_mods_t {
    var rawValue: Int32 = 0
    if precision {
      rawValue |= 0b0000_0001
    }
    rawValue |= Int32(momentum(from: momentumPhase).rawValue) << 1
    return rawValue
  }

  private static func momentum(from phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
    switch phase {
    case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
    case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
    case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
    case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
    case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
    case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
    default: GHOSTTY_MOUSE_MOMENTUM_NONE
    }
  }
}
