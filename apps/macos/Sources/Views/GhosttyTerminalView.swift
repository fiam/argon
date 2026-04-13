import AppKit
import GhosttyKit
import SwiftUI

private struct UnsafeRawPointerBox: @unchecked Sendable {
  let value: UnsafeMutableRawPointer?
}

private final class WeakGhosttyHostBox {
  weak var host: GhosttyTerminalHostView?

  init(host: GhosttyTerminalHostView) {
    self.host = host
  }
}

private enum GhosttyHostRegistry {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var nextIdentifier: UInt = 1
  nonisolated(unsafe) private static var hosts: [UInt: WeakGhosttyHostBox] = [:]

  static func register(_ host: GhosttyTerminalHostView) -> UnsafeMutableRawPointer {
    lock.lock()
    defer { lock.unlock() }

    let identifier = nextIdentifier
    nextIdentifier &+= 1
    hosts[identifier] = WeakGhosttyHostBox(host: host)
    return UnsafeMutableRawPointer(bitPattern: identifier)!
  }

  static func host(for userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalHostView? {
    guard let userdata else { return nil }
    let identifier = UInt(bitPattern: userdata)

    lock.lock()
    defer { lock.unlock() }

    guard let box = hosts[identifier] else { return nil }
    if let host = box.host {
      return host
    }

    hosts.removeValue(forKey: identifier)
    return nil
  }

  static func unregister(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let identifier = UInt(bitPattern: userdata)

    lock.lock()
    hosts.removeValue(forKey: identifier)
    lock.unlock()
  }
}

private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
  GhosttyTerminalHostView.wakeup(userdata)
}

private func ghosttyActionCallback(
  _ app: ghostty_app_t?,
  _ target: ghostty_target_s,
  _ action: ghostty_action_s
) -> Bool {
  guard let app else { return false }
  return GhosttyTerminalHostView.action(app, target: target, action: action)
}

private func ghosttyReadClipboardCallback(
  _ userdata: UnsafeMutableRawPointer?,
  _ location: ghostty_clipboard_e,
  _ state: UnsafeMutableRawPointer?
) -> Bool {
  GhosttyTerminalHostView.readClipboard(userdata, location: location, state: state)
}

private func ghosttyConfirmReadClipboardCallback(
  _ userdata: UnsafeMutableRawPointer?,
  _ text: UnsafePointer<CChar>?,
  _ state: UnsafeMutableRawPointer?,
  _ request: ghostty_clipboard_request_e
) {
}

private func ghosttyWriteClipboardCallback(
  _ userdata: UnsafeMutableRawPointer?,
  _ location: ghostty_clipboard_e,
  _ content: UnsafePointer<ghostty_clipboard_content_s>?,
  _ len: Int,
  _ confirm: Bool
) {
  GhosttyTerminalHostView.writeClipboard(
    userdata,
    location: location,
    content: content,
    len: len,
    confirm: confirm
  )
}

private func ghosttyCloseSurfaceCallback(
  _ userdata: UnsafeMutableRawPointer?,
  _ processAlive: Bool
) {
  GhosttyTerminalHostView.closeSurface(userdata, processAlive: processAlive)
}

struct GhosttyTerminalView: NSViewRepresentable {
  let controller: any TerminalProcessControlling
  let launch: TerminalLaunchConfiguration
  var terminalFontSize: CGFloat = 12
  var waitAfterCommand = true
  var onProcessExit: (() -> Void)?
  var focusRequestID: UUID?

  @MainActor
  init(agent: ReviewerAgentInstance, terminalFontSize: CGFloat = 12) {
    self.controller = agent
    self.launch = .forReviewerAgent(agent)
    self.terminalFontSize = terminalFontSize
  }

  init(
    controller: any TerminalProcessControlling,
    launch: TerminalLaunchConfiguration,
    terminalFontSize: CGFloat = 12,
    waitAfterCommand: Bool = true,
    onProcessExit: (() -> Void)? = nil,
    focusRequestID: UUID? = nil
  ) {
    self.controller = controller
    self.launch = launch
    self.terminalFontSize = terminalFontSize
    self.waitAfterCommand = waitAfterCommand
    self.onProcessExit = onProcessExit
    self.focusRequestID = focusRequestID
  }

  func makeNSView(context: Context) -> GhosttyTerminalHostView {
    UITestAutomationSignal.write(
      "ghostty-terminal-host-created",
      to: UITestAutomationConfig.current().signalFilePath
    )
    return GhosttyTerminalHostView(
      controller: controller,
      launch: launch,
      terminalFontSize: terminalFontSize,
      waitAfterCommand: waitAfterCommand,
      onProcessExit: onProcessExit,
      focusRequestID: focusRequestID
    )
  }

  func updateNSView(_ nsView: GhosttyTerminalHostView, context: Context) {
    nsView.updateTerminalFontSize(terminalFontSize)
    nsView.updateProcessExitHandler(onProcessExit)
    nsView.updateFocusRequestID(focusRequestID)
  }

  static func dismantleNSView(_ nsView: GhosttyTerminalHostView, coordinator: ()) {
    nsView.shutdown()
  }
}

final class GhosttyTerminalHostView: NSView {
  private let controller: any TerminalProcessControlling
  private let launch: TerminalLaunchConfiguration
  private var terminalFontSize: CGFloat
  private let waitAfterCommand: Bool
  private var onProcessExit: (() -> Void)?
  private var pendingFocusRequestID: UUID?
  private var appliedFocusRequestID: UUID?
  private var callbackUserdata: UnsafeMutableRawPointer?
  private var app: ghostty_app_t?
  private var config: ghostty_config_t?
  private var surface: ghostty_surface_t?
  private var processPollTimer: Timer?
  private var didMarkProcessExited = false
  private var markedText = NSMutableAttributedString()
  private var keyTextAccumulator: [String]?
  private var eventMonitor: Any?
  private var cellSize = NSSize(width: 8, height: 16)

  private lazy var messageLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.alignment = .center
    label.maximumNumberOfLines = 0
    label.textColor = .secondaryLabelColor
    label.font = NSFont.systemFont(ofSize: 13)
    return label
  }()

  override var acceptsFirstResponder: Bool { true }

  init(
    controller: any TerminalProcessControlling,
    launch: TerminalLaunchConfiguration,
    terminalFontSize: CGFloat,
    waitAfterCommand: Bool,
    onProcessExit: (() -> Void)?,
    focusRequestID: UUID?
  ) {
    self.controller = controller
    self.launch = launch
    self.terminalFontSize = terminalFontSize
    self.waitAfterCommand = waitAfterCommand
    self.onProcessExit = onProcessExit
    self.pendingFocusRequestID = focusRequestID
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    self.callbackUserdata = GhosttyHostRegistry.register(self)
    initializeTerminal()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for GhosttyTerminalHostView")
  }

  func shutdown() {
    GhosttyHostRegistry.unregister(callbackUserdata)
    callbackUserdata = nil

    processPollTimer?.invalidate()
    processPollTimer = nil

    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }

    if let surface {
      ghostty_surface_free(surface)
      self.surface = nil
    }
    if let app {
      ghostty_app_free(app)
      self.app = nil
    }
    if let config {
      ghostty_config_free(config)
      self.config = nil
    }
  }

  func updateTerminalFontSize(_ newValue: CGFloat) {
    terminalFontSize = newValue
  }

  func updateProcessExitHandler(_ onProcessExit: (() -> Void)?) {
    self.onProcessExit = onProcessExit
  }

  func updateFocusRequestID(_ focusRequestID: UUID?) {
    pendingFocusRequestID = focusRequestID
    applyPendingFocusRequestIfNeeded()
  }

  override func layout() {
    super.layout()
    updateSurfaceMetrics()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateSurfaceMetrics()
    applyPendingFocusRequestIfNeeded()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateSurfaceMetrics()
  }

  override func updateTrackingAreas() {
    trackingAreas.forEach(removeTrackingArea)

    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
        owner: self,
        userInfo: nil
      ))
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result, let surface {
      ghostty_surface_set_focus(surface, true)
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result, let surface {
      ghostty_surface_set_focus(surface, false)
    }
    return result
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    sendMouseButton(GHOSTTY_MOUSE_PRESS, event: event)
  }

  override func mouseUp(with event: NSEvent) {
    sendMouseButton(GHOSTTY_MOUSE_RELEASE, event: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    sendMouseButton(GHOSTTY_MOUSE_PRESS, event: event)
  }

  override func rightMouseUp(with event: NSEvent) {
    sendMouseButton(GHOSTTY_MOUSE_RELEASE, event: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    sendMouseButton(GHOSTTY_MOUSE_PRESS, event: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    sendMouseButton(GHOSTTY_MOUSE_RELEASE, event: event)
  }

  override func mouseEntered(with event: NSEvent) {
    sendMousePosition(for: event)
  }

  override func mouseExited(with event: NSEvent) {
    guard let surface else { return }
    if NSEvent.pressedMouseButtons == 0 {
      ghostty_surface_mouse_pos(
        surface, -1, -1, GhosttyInputBridge.modifiers(from: event.modifierFlags))
    }
  }

  override func mouseMoved(with event: NSEvent) {
    sendMousePosition(for: event)
  }

  override func mouseDragged(with event: NSEvent) {
    sendMousePosition(for: event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    sendMousePosition(for: event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    sendMousePosition(for: event)
  }

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }

    var deltaX = event.scrollingDeltaX
    var deltaY = event.scrollingDeltaY
    if event.hasPreciseScrollingDeltas {
      deltaX *= 2
      deltaY *= 2
    }

    ghostty_surface_mouse_scroll(
      surface,
      deltaX,
      deltaY,
      GhosttyInputBridge.scrollMods(
        precision: event.hasPreciseScrollingDeltas,
        momentumPhase: event.momentumPhase
      )
    )
  }

  override func keyDown(with event: NSEvent) {
    guard let surface else {
      interpretKeyEvents([event])
      return
    }

    let translationFlags = GhosttyInputBridge.eventModifierFlags(
      from: ghostty_surface_key_translation_mods(
        surface,
        GhosttyInputBridge.modifiers(from: event.modifierFlags)
      ))

    var translationModifiers = event.modifierFlags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      if translationFlags.contains(flag) {
        translationModifiers.insert(flag)
      } else {
        translationModifiers.remove(flag)
      }
    }

    let translationEvent =
      if translationModifiers == event.modifierFlags {
        event
      } else {
        NSEvent.keyEvent(
          with: event.type,
          location: event.locationInWindow,
          modifierFlags: translationModifiers,
          timestamp: event.timestamp,
          windowNumber: event.windowNumber,
          context: nil,
          characters: event.characters(byApplyingModifiers: translationModifiers) ?? "",
          charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
          isARepeat: event.isARepeat,
          keyCode: event.keyCode
        ) ?? event
      }

    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    let markedTextBefore = hasMarkedText()

    keyTextAccumulator = []
    defer { keyTextAccumulator = nil }

    interpretKeyEvents([translationEvent])
    syncPreedit(clearIfNeeded: markedTextBefore)

    if let texts = keyTextAccumulator, !texts.isEmpty {
      for text in texts {
        _ = sendKeyAction(
          action,
          event: event,
          translationEvent: translationEvent,
          text: text,
          composing: false
        )
      }
    } else {
      _ = sendKeyAction(
        action,
        event: event,
        translationEvent: translationEvent,
        text: GhosttyInputBridge.textForKeyEvent(from: translationEvent),
        composing: markedText.length > 0 || markedTextBefore
      )
    }
  }

  override func keyUp(with event: NSEvent) {
    _ = sendKeyAction(GHOSTTY_ACTION_RELEASE, event: event)
  }

  override func flagsChanged(with event: NSEvent) {
    guard !hasMarkedText() else { return }

    let modifierBit: UInt32
    switch event.keyCode {
    case 0x39: modifierBit = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: modifierBit = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: modifierBit = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: modifierBit = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: modifierBit = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }

    let mods = GhosttyInputBridge.modifiers(from: event.modifierFlags)
    var action = GHOSTTY_ACTION_RELEASE
    if mods.rawValue & modifierBit != 0 {
      let sidePressed: Bool
      switch event.keyCode {
      case 0x3C:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
      case 0x3E:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
      case 0x3D:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
      case 0x36:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
      default:
        sidePressed = true
      }

      if sidePressed {
        action = GHOSTTY_ACTION_PRESS
      }
    }

    _ = sendKeyAction(action, event: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    guard window?.firstResponder === self else { return false }

    if shouldPassThroughAppShortcut(event) {
      return false
    }

    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
      keyDown(with: event)
      return true
    }

    return false
  }

  @IBAction func copy(_ sender: Any?) {
    _ = performBindingAction("copy_to_clipboard")
  }

  @IBAction func paste(_ sender: Any?) {
    _ = performBindingAction("paste_from_clipboard")
  }

  @IBAction override func selectAll(_ sender: Any?) {
    _ = performBindingAction("select_all")
  }

  private func initializeTerminal() {
    do {
      try GhosttyRuntime.ensureInitialized()
    } catch {
      showMessage("Ghostty failed to initialize.")
      return
    }

    guard let config = ghostty_config_new() else {
      showMessage("Ghostty failed to create its default configuration.")
      return
    }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)
    self.config = config

    var runtimeConfig = ghostty_runtime_config_s(
      userdata: callbackUserdata,
      supports_selection_clipboard: true,
      wakeup_cb: ghosttyWakeupCallback,
      action_cb: ghosttyActionCallback,
      read_clipboard_cb: ghosttyReadClipboardCallback,
      confirm_read_clipboard_cb: ghosttyConfirmReadClipboardCallback,
      write_clipboard_cb: ghosttyWriteClipboardCallback,
      close_surface_cb: ghosttyCloseSurfaceCallback
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      showMessage("Ghostty failed to create an embedded app instance.")
      return
    }
    self.app = app
    ghostty_app_set_focus(app, NSApp.isActive)

    guard let surface = createSurface(for: app) else {
      showMessage("Ghostty failed to create a terminal surface.")
      return
    }
    self.surface = surface

    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyUp]
    ) { [weak self] event in
      self?.localEventHandler(event)
    }

    startProcessPollTimer()
    updateTrackingAreas()
    updateSurfaceMetrics()
  }

  private func createSurface(for app: ghostty_app_t) -> ghostty_surface_t? {
    var surfaceConfig = ghostty_surface_config_new()
    surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
    surfaceConfig.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(self).toOpaque()
      ))
    surfaceConfig.userdata = callbackUserdata
    let scaleFactor =
      window.map { Double($0.backingScaleFactor) }
      ?? NSScreen.main.map { Double($0.backingScaleFactor) }
      ?? 2.0
    surfaceConfig.scale_factor = scaleFactor
    surfaceConfig.font_size = Float32(terminalFontSize)
    surfaceConfig.wait_after_command = waitAfterCommand

    let envPairs = launch.environment.keys.sorted().map { key in
      (key, launch.environment[key] ?? "")
    }
    let command = launch.ghosttyCommand

    return launch.currentDirectory.withCString { workingDirectory in
      command.withCString { commandPointer in
        envPairs.map(\.0).withCStrings { keys in
          envPairs.map(\.1).withCStrings { values in
            var envVars: [ghostty_env_var_s] = []
            envVars.reserveCapacity(envPairs.count)
            for index in envPairs.indices {
              envVars.append(
                ghostty_env_var_s(
                  key: keys[index],
                  value: values[index]
                ))
            }
            let envVarCount = envVars.count

            return envVars.withUnsafeMutableBufferPointer { buffer in
              surfaceConfig.working_directory = workingDirectory
              surfaceConfig.command = commandPointer
              surfaceConfig.env_vars = buffer.baseAddress
              surfaceConfig.env_var_count = envVarCount
              surfaceConfig.initial_input = nil
              return ghostty_surface_new(app, &surfaceConfig)
            }
          }
        }
      }
    }
  }

  private func updateSurfaceMetrics() {
    guard let surface else { return }
    guard bounds.width > 0, bounds.height > 0 else { return }

    let backingBounds = convertToBacking(bounds)
    let xScale = backingBounds.width / bounds.width
    let yScale = backingBounds.height / bounds.height

    ghostty_surface_set_content_scale(surface, xScale, yScale)
    ghostty_surface_set_size(
      surface,
      UInt32(max(backingBounds.width.rounded(), 1)),
      UInt32(max(backingBounds.height.rounded(), 1))
    )

    let size = ghostty_surface_size(surface)
    if size.cell_width_px > 0, size.cell_height_px > 0 {
      cellSize = NSSize(
        width: CGFloat(size.cell_width_px) / max(xScale, 1),
        height: CGFloat(size.cell_height_px) / max(yScale, 1)
      )
    }
  }

  private func startProcessPollTimer() {
    processPollTimer?.invalidate()
    processPollTimer = Timer.scheduledTimer(
      withTimeInterval: 0.5,
      repeats: true
    ) { [weak self] _ in
      self?.syncProcessState()
    }
  }

  private func syncProcessState() {
    guard let surface else { return }
    if !didMarkProcessExited && ghostty_surface_process_exited(surface) {
      markProcessExited()
    }
  }

  private func markProcessExited() {
    guard !didMarkProcessExited else { return }
    didMarkProcessExited = true
    controller.isRunning = false
    if let onProcessExit {
      Task { @MainActor in
        onProcessExit()
      }
    }
  }

  private func applyPendingFocusRequestIfNeeded() {
    guard let requestID = pendingFocusRequestID, appliedFocusRequestID != requestID else { return }
    guard window != nil else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.pendingFocusRequestID == requestID, self.appliedFocusRequestID != requestID else {
        return
      }
      guard let window = self.window else { return }

      if window.firstResponder !== self {
        _ = window.makeFirstResponder(self)
      }
      self.appliedFocusRequestID = requestID
    }
  }

  private func showMessage(_ message: String) {
    if messageLabel.superview == nil {
      addSubview(messageLabel)
      NSLayoutConstraint.activate([
        messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
      ])
    }

    messageLabel.stringValue = message
  }

  private func appTick() {
    if let app {
      ghostty_app_tick(app)
    }
  }

  private func sendMouseButton(
    _ state: ghostty_input_mouse_state_e,
    event: NSEvent
  ) {
    guard let surface else { return }

    ghostty_surface_mouse_button(
      surface,
      state,
      GhosttyInputBridge.mouseButton(from: event.buttonNumber),
      GhosttyInputBridge.modifiers(from: event.modifierFlags)
    )
  }

  private func sendMousePosition(for event: NSEvent) {
    guard let surface else { return }

    let position = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface,
      position.x,
      bounds.height - position.y,
      GhosttyInputBridge.modifiers(from: event.modifierFlags)
    )
  }

  private func sendKeyAction(
    _ action: ghostty_input_action_e,
    event: NSEvent,
    translationEvent: NSEvent? = nil,
    text: String? = nil,
    composing: Bool = false
  ) -> Bool {
    guard let surface else { return false }

    var keyEvent = GhosttyInputBridge.keyEvent(
      from: event,
      action: action,
      translationModifiers: translationEvent?.modifierFlags,
      composing: composing
    )

    if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
      return text.withCString { pointer in
        keyEvent.text = pointer
        return ghostty_surface_key(surface, keyEvent)
      }
    }

    return ghostty_surface_key(surface, keyEvent)
  }

  private func performBindingAction(_ action: String) -> Bool {
    guard let surface else { return false }
    return action.withCString { pointer in
      ghostty_surface_binding_action(surface, pointer, UInt(action.lengthOfBytes(using: .utf8)))
    }
  }

  private func localEventHandler(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .keyUp:
      return localEventKeyUp(event)
    default:
      return event
    }
  }

  private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
    guard event.modifierFlags.contains(.command) else { return event }
    guard window?.firstResponder === self else { return event }
    if shouldPassThroughAppShortcut(event) { return event }
    keyUp(with: event)
    return nil
  }

  private func shouldPassThroughAppShortcut(_ event: NSEvent) -> Bool {
    guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
    guard characters == "t" else { return false }

    let relevantModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
    switch relevantModifiers {
    case [.command], [.command, .shift], [.command, .shift, .option]:
      return true
    default:
      return false
    }
  }

  private func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface else { return }

    if markedText.length > 0 {
      let string = markedText.string
      let length = string.utf8CString.count
      if length > 0 {
        string.withCString { pointer in
          ghostty_surface_preedit(surface, pointer, UInt(length - 1))
        }
      }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  nonisolated fileprivate static func host(from userdata: UnsafeMutableRawPointer?)
    -> GhosttyTerminalHostView?
  {
    GhosttyHostRegistry.host(for: userdata)
  }

  nonisolated fileprivate static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
    let userdataBox = UnsafeRawPointerBox(value: userdata)
    MainActorDispatch.async {
      guard let host = host(from: userdataBox.value) else { return }
      host.appTick()
    }
  }

  nonisolated fileprivate static func action(
    _ app: ghostty_app_t,
    target: ghostty_target_s,
    action: ghostty_action_s
  ) -> Bool {
    false
  }

  nonisolated fileprivate static func readClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?
  ) -> Bool {
    guard location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
    let userdataBox = UnsafeRawPointerBox(value: userdata)
    let stateBox = UnsafeRawPointerBox(value: state)

    return MainActorDispatch.sync {
      guard let host = host(from: userdataBox.value), let surface = host.surface else {
        return false
      }
      guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
        return false
      }

      text.withCString { pointer in
        ghostty_surface_complete_clipboard_request(surface, pointer, stateBox.value, false)
      }
      return true
    }
  }

  nonisolated fileprivate static func writeClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    len: Int,
    confirm: Bool
  ) {
    guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }
    guard let content, len > 0 else { return }

    let items = UnsafeBufferPointer(start: content, count: len)
    guard
      let plainText = items.first(where: { item in
        guard let mime = item.mime else { return false }
        return String(cString: mime) == "text/plain"
      }),
      let value = plainText.data
    else {
      return
    }

    let text = String(cString: value)
    MainActorDispatch.async {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
  }

  nonisolated fileprivate static func closeSurface(
    _ userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
  ) {
    if !processAlive {
      let userdataBox = UnsafeRawPointerBox(value: userdata)
      MainActorDispatch.async {
        guard let host = host(from: userdataBox.value) else { return }
        host.markProcessExited()
      }
    }
  }
}

extension GhosttyTerminalHostView: NSTextInputClient {
  nonisolated func hasMarkedText() -> Bool {
    MainActorDispatch.sync { [self] in
      self.markedText.length > 0
    }
  }

  nonisolated func markedRange() -> NSRange {
    MainActorDispatch.sync { [self] in
      guard self.markedText.length > 0 else { return NSRange() }
      return NSRange(location: 0, length: self.markedText.length)
    }
  }

  nonisolated func selectedRange() -> NSRange {
    MainActorDispatch.sync { [self] in
      guard let surface = self.surface else { return NSRange() }

      var text = ghostty_text_s()
      guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
      defer { ghostty_surface_free_text(surface, &text) }
      return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }
  }

  nonisolated func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    let resolvedText: String
    switch string {
    case let value as NSAttributedString:
      resolvedText = value.string
    case let value as String:
      resolvedText = value
    default:
      return
    }

    MainActorDispatch.sync { [self] in
      self.markedText = NSMutableAttributedString(string: resolvedText)

      if self.keyTextAccumulator == nil {
        self.syncPreedit()
      }
    }
  }

  nonisolated func unmarkText() {
    MainActorDispatch.sync { [self] in
      if self.markedText.length > 0 {
        self.markedText.mutableString.setString("")
        self.syncPreedit()
      }
    }
  }

  nonisolated func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  nonisolated func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    let selectedText: String? = MainActorDispatch.sync { [self] in
      guard let surface = self.surface else { return nil }
      guard range.length > 0 else { return nil }

      var text = ghostty_text_s()
      guard ghostty_surface_read_selection(surface, &text) else { return nil }
      defer { ghostty_surface_free_text(surface, &text) }
      return String(cString: text.text)
    }

    guard let selectedText else { return nil }
    return NSAttributedString(string: selectedText)
  }

  nonisolated func characterIndex(for point: NSPoint) -> Int {
    0
  }

  nonisolated func firstRect(
    forCharacterRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSRect {
    MainActorDispatch.sync { [self] in
      guard let surface = self.surface else {
        return NSRect(x: self.frame.origin.x, y: self.frame.origin.y, width: 0, height: 0)
      }

      var x: Double = 0
      var y: Double = 0
      var width: Double = self.cellSize.width
      var height: Double = self.cellSize.height
      ghostty_surface_ime_point(surface, &x, &y, &width, &height)

      if range.length == 0, width > 0 {
        width = 0
        x += self.cellSize.width * Double(range.location + range.length)
      }

      let viewRect = NSRect(
        x: x,
        y: self.bounds.height - y,
        width: width,
        height: max(height, self.cellSize.height)
      )
      let windowRect = self.convert(viewRect, to: nil)
      guard let window = self.window else { return windowRect }
      return window.convertToScreen(windowRect)
    }
  }

  nonisolated func insertText(_ string: Any, replacementRange: NSRange) {
    let characters: String
    switch string {
    case let value as NSAttributedString:
      characters = value.string
    case let value as String:
      characters = value
    default:
      return
    }

    MainActorDispatch.sync { [self] in
      guard let surface = self.surface else { return }
      if self.markedText.length > 0 {
        self.markedText.mutableString.setString("")
        self.syncPreedit()
      }

      if var accumulator = self.keyTextAccumulator {
        accumulator.append(characters)
        self.keyTextAccumulator = accumulator
        return
      }

      characters.withCString { pointer in
        ghostty_surface_text(surface, pointer, UInt(characters.lengthOfBytes(using: .utf8)))
      }
    }
  }

  nonisolated override func doCommand(by selector: Selector) {
    MainActorDispatch.sync { [self] in
      switch selector {
      case #selector(self.moveToBeginningOfDocument(_:)):
        _ = self.performBindingAction("scroll_to_top")
      case #selector(self.moveToEndOfDocument(_:)):
        _ = self.performBindingAction("scroll_to_bottom")
      default:
        break
      }
    }
  }
}

extension Array where Element == String {
  fileprivate func withCStrings<T>(_ body: ([UnsafePointer<CChar>?]) throws -> T) rethrows -> T {
    if isEmpty {
      return try body([])
    }

    func recurse(
      index: Int,
      accumulated: [UnsafePointer<CChar>?],
      body: ([UnsafePointer<CChar>?]) throws -> T
    ) rethrows -> T {
      if index == count {
        return try body(accumulated)
      }

      return try self[index].withCString { cString in
        var next = accumulated
        next.append(cString)
        return try recurse(index: index + 1, accumulated: next, body: body)
      }
    }

    return try recurse(index: 0, accumulated: [], body: body)
  }
}
