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
  nonisolated(unsafe) private static var hostsByTerminalID: [UUID: WeakGhosttyHostBox] = [:]
  nonisolated(unsafe) private static var retainedHostsByTerminalID:
    [UUID: GhosttyTerminalHostView] =
      [:]

  static func register(
    _ host: GhosttyTerminalHostView,
    terminalID: UUID?
  ) -> UnsafeMutableRawPointer {
    lock.lock()
    defer { lock.unlock() }

    let identifier = nextIdentifier
    nextIdentifier &+= 1
    hosts[identifier] = WeakGhosttyHostBox(host: host)
    if let terminalID {
      hostsByTerminalID[terminalID] = WeakGhosttyHostBox(host: host)
    }
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

  static func unregister(_ userdata: UnsafeMutableRawPointer?, terminalID: UUID?) {
    guard let userdata else { return }
    let identifier = UInt(bitPattern: userdata)

    lock.lock()
    hosts.removeValue(forKey: identifier)
    if let terminalID, retainedHostsByTerminalID[terminalID] == nil {
      hostsByTerminalID.removeValue(forKey: terminalID)
    }
    lock.unlock()
  }

  static func host(for terminalID: UUID) -> GhosttyTerminalHostView? {
    lock.lock()
    defer { lock.unlock() }

    if let host = retainedHostsByTerminalID[terminalID] {
      return host
    }

    guard let box = hostsByTerminalID[terminalID] else { return nil }
    if let host = box.host {
      return host
    }

    hostsByTerminalID.removeValue(forKey: terminalID)
    return nil
  }

  static func retain(_ host: GhosttyTerminalHostView, terminalID: UUID?) {
    guard let terminalID else { return }

    lock.lock()
    retainedHostsByTerminalID[terminalID] = host
    hostsByTerminalID[terminalID] = WeakGhosttyHostBox(host: host)
    lock.unlock()
  }

  static func releaseRetainedHost(for terminalID: UUID) -> GhosttyTerminalHostView? {
    lock.lock()
    let host = retainedHostsByTerminalID.removeValue(forKey: terminalID)
    hostsByTerminalID.removeValue(forKey: terminalID)
    lock.unlock()
    return host
  }

  static func isRetained(_ host: GhosttyTerminalHostView, terminalID: UUID?) -> Bool {
    guard let terminalID else { return false }

    lock.lock()
    defer { lock.unlock() }
    return retainedHostsByTerminalID[terminalID] === host
  }
}

enum GhosttyAppShortcutPassthrough {
  private static let supportedModifiers: NSEvent.ModifierFlags = [
    .command, .shift, .option, .control,
  ]

  @MainActor
  static func shouldPassThrough(
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    menu: NSMenu? = nil
  ) -> Bool {
    guard let characters = charactersIgnoringModifiers?.lowercased() else { return false }
    let relevantModifiers = modifierFlags.intersection(supportedModifiers)
    return menuContainsShortcut(
      menu ?? NSApp.mainMenu,
      charactersIgnoringModifiers: characters,
      modifierFlags: relevantModifiers
    )
  }

  @MainActor
  private static func menuContainsShortcut(
    _ menu: NSMenu?,
    charactersIgnoringModifiers: String,
    modifierFlags: NSEvent.ModifierFlags
  ) -> Bool {
    guard let menu else { return false }

    for item in menu.items {
      if item.isEnabled {
        let keyEquivalent = item.keyEquivalent.lowercased()
        let keyEquivalentModifiers = item.keyEquivalentModifierMask.intersection(supportedModifiers)
        if !keyEquivalent.isEmpty,
          keyEquivalent == charactersIgnoringModifiers,
          keyEquivalentModifiers == modifierFlags
        {
          return true
        }
      }

      if menuContainsShortcut(
        item.submenu,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifierFlags: modifierFlags
      ) {
        return true
      }
    }

    return false
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
  let terminalID: UUID?
  var terminalFontSize: CGFloat = 12
  var ghosttyConfigurationText = ""
  var waitAfterCommand = true
  var onProcessExit: (() -> Void)?
  var onAttention: ((TerminalAttentionEvent) -> Void)?
  var onTitleChange: ((TerminalTitleChange) -> Void)?
  var focusRequestID: UUID?

  @MainActor
  init(
    agent: ReviewerAgentInstance,
    terminalFontSize: CGFloat = 12,
    ghosttyConfigurationText: String = ""
  ) {
    self.controller = agent
    self.launch = .forReviewerAgent(agent)
    self.terminalID = nil
    self.terminalFontSize = terminalFontSize
    self.ghosttyConfigurationText = ghosttyConfigurationText
  }

  init(
    controller: any TerminalProcessControlling,
    launch: TerminalLaunchConfiguration,
    terminalID: UUID? = nil,
    terminalFontSize: CGFloat = 12,
    ghosttyConfigurationText: String = "",
    waitAfterCommand: Bool = true,
    onProcessExit: (() -> Void)? = nil,
    onAttention: ((TerminalAttentionEvent) -> Void)? = nil,
    onTitleChange: ((TerminalTitleChange) -> Void)? = nil,
    focusRequestID: UUID? = nil
  ) {
    self.controller = controller
    self.launch = launch
    self.terminalID = terminalID
    self.terminalFontSize = terminalFontSize
    self.ghosttyConfigurationText = ghosttyConfigurationText
    self.waitAfterCommand = waitAfterCommand
    self.onProcessExit = onProcessExit
    self.onAttention = onAttention
    self.onTitleChange = onTitleChange
    self.focusRequestID = focusRequestID
  }

  func makeNSView(context: Context) -> GhosttyTerminalHostView {
    if let terminalID, let host = GhosttyHostRegistry.host(for: terminalID) {
      host.prepareForAttachment()
      UITestAutomationSignal.write(
        "ghostty-terminal-host-created",
        to: UITestAutomationConfig.current().signalFilePath
      )
      return host
    }

    UITestAutomationSignal.write(
      "ghostty-terminal-host-created",
      to: UITestAutomationConfig.current().signalFilePath
    )
    return GhosttyTerminalHostView(
      controller: controller,
      launch: launch,
      terminalID: terminalID,
      terminalFontSize: terminalFontSize,
      ghosttyConfigurationText: ghosttyConfigurationText,
      waitAfterCommand: waitAfterCommand,
      onProcessExit: onProcessExit,
      onAttention: onAttention,
      onTitleChange: onTitleChange,
      focusRequestID: focusRequestID
    )
  }

  func updateNSView(_ nsView: GhosttyTerminalHostView, context: Context) {
    nsView.updateTerminalFontSize(terminalFontSize)
    nsView.updateGhosttyConfigurationText(ghosttyConfigurationText)
    nsView.updateProcessExitHandler(onProcessExit)
    nsView.updateAttentionHandler(onAttention)
    nsView.updateTitleChangeHandler(onTitleChange)
    nsView.updateFocusRequestID(focusRequestID)
  }

  static func dismantleNSView(_ nsView: GhosttyTerminalHostView, coordinator: ()) {
    if GhosttyHostRegistry.isRetained(nsView, terminalID: nsView.terminalID) {
      nsView.prepareForDetachment()
      return
    }
    nsView.shutdown()
  }

  @MainActor
  static func injectText(
    _ text: String,
    into terminalID: UUID,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
      if let host = GhosttyHostRegistry.host(for: terminalID) {
        host.injectText(text)
        return true
      }

      try? await Task.sleep(for: .milliseconds(50))
    }

    return false
  }

  @MainActor
  static func injectPrompt(
    _ prompt: String,
    into terminalID: UUID,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
      if let host = GhosttyHostRegistry.host(for: terminalID) {
        host.injectText(prompt)
        host.submitReturn()
        return true
      }

      try? await Task.sleep(for: .milliseconds(50))
    }

    return false
  }

  @MainActor
  static func releaseTerminal(_ terminalID: UUID) {
    GhosttyHostRegistry.releaseRetainedHost(for: terminalID)?.shutdown()
  }
}

final class GhosttyTerminalHostView: NSView {
  private let controller: any TerminalProcessControlling
  private let launch: TerminalLaunchConfiguration
  let terminalID: UUID?
  private var terminalFontSize: CGFloat
  private var ghosttyConfigurationText: String
  private let waitAfterCommand: Bool
  private var onProcessExit: (() -> Void)?
  private var onAttention: ((TerminalAttentionEvent) -> Void)?
  private var onTitleChange: ((TerminalTitleChange) -> Void)?
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
  private var appDidBecomeActiveObserver: NSObjectProtocol?
  private var appDidResignActiveObserver: NSObjectProtocol?
  private var windowDidBecomeKeyObserver: NSObjectProtocol?
  private var windowDidResignKeyObserver: NSObjectProtocol?
  private weak var observedWindow: NSWindow?
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
    terminalID: UUID?,
    terminalFontSize: CGFloat,
    ghosttyConfigurationText: String,
    waitAfterCommand: Bool,
    onProcessExit: (() -> Void)?,
    onAttention: ((TerminalAttentionEvent) -> Void)?,
    onTitleChange: ((TerminalTitleChange) -> Void)?,
    focusRequestID: UUID?
  ) {
    self.controller = controller
    self.launch = launch
    self.terminalID = terminalID
    self.terminalFontSize = terminalFontSize
    self.ghosttyConfigurationText = ghosttyConfigurationText
    self.waitAfterCommand = waitAfterCommand
    self.onProcessExit = onProcessExit
    self.onAttention = onAttention
    self.onTitleChange = onTitleChange
    self.pendingFocusRequestID = focusRequestID
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    self.callbackUserdata = GhosttyHostRegistry.register(self, terminalID: terminalID)
    GhosttyHostRegistry.retain(self, terminalID: terminalID)
    installApplicationFocusObservers()
    initializeTerminal()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for GhosttyTerminalHostView")
  }

  func shutdown() {
    prepareForDetachment()
    GhosttyHostRegistry.unregister(callbackUserdata, terminalID: terminalID)
    callbackUserdata = nil

    processPollTimer?.invalidate()
    processPollTimer = nil

    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }

    removeWindowFocusObservers()
    removeApplicationFocusObservers()

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

  func prepareForAttachment() {
    if let superview {
      removeFromSuperview()
      superview.layoutSubtreeIfNeeded()
    }
  }

  func prepareForDetachment() {
    window?.makeFirstResponder(nil)
    removeFromSuperview()
  }

  func updateTerminalFontSize(_ newValue: CGFloat) {
    terminalFontSize = newValue
  }

  func updateGhosttyConfigurationText(_ newValue: String) {
    guard ghosttyConfigurationText != newValue else { return }
    ghosttyConfigurationText = newValue
    reloadGhosttyConfiguration()
  }

  func updateProcessExitHandler(_ onProcessExit: (() -> Void)?) {
    self.onProcessExit = onProcessExit
  }

  func updateAttentionHandler(_ onAttention: ((TerminalAttentionEvent) -> Void)?) {
    self.onAttention = onAttention
  }

  func updateTitleChangeHandler(_ onTitleChange: ((TerminalTitleChange) -> Void)?) {
    self.onTitleChange = onTitleChange
  }

  func updateFocusRequestID(_ focusRequestID: UUID?) {
    pendingFocusRequestID = focusRequestID
    applyPendingFocusRequestIfNeeded()
  }

  func injectText(_ characters: String) {
    guard let surface else { return }
    if markedText.length > 0 {
      markedText.mutableString.setString("")
      syncPreedit()
    }

    characters.withCString { pointer in
      ghostty_surface_text(surface, pointer, UInt(characters.lengthOfBytes(using: .utf8)))
    }
  }

  func submitReturn() {
    window?.makeFirstResponder(self)

    let timestamp = ProcessInfo.processInfo.systemUptime
    let windowNumber = window?.windowNumber ?? 0
    let keyCode: UInt16 = 36

    guard
      let keyDown = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: keyCode
      ),
      let keyUp = NSEvent.keyEvent(
        with: .keyUp,
        location: .zero,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: keyCode
      )
    else {
      insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
      return
    }

    _ = sendKeyAction(GHOSTTY_ACTION_PRESS, event: keyDown)
    _ = sendKeyAction(GHOSTTY_ACTION_RELEASE, event: keyUp)
  }

  override func layout() {
    super.layout()
    updateSurfaceMetrics()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateWindowFocusObservers()
    updateSurfaceMetrics()
    syncEmbeddedFocusState()
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
    if result {
      syncEmbeddedFocusState()
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      syncEmbeddedFocusState()
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

    guard let config = loadGhosttyConfiguration() else {
      showMessage("Ghostty failed to load terminal configuration.")
      return
    }
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
    syncEmbeddedFocusState()
  }

  private func installApplicationFocusObservers() {
    let center = NotificationCenter.default
    appDidBecomeActiveObserver = center.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: NSApp,
      queue: .main
    ) { [weak self] _ in
      self?.syncEmbeddedFocusState()
    }
    appDidResignActiveObserver = center.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: NSApp,
      queue: .main
    ) { [weak self] _ in
      self?.syncEmbeddedFocusState()
    }
  }

  private func removeApplicationFocusObservers() {
    let center = NotificationCenter.default
    if let appDidBecomeActiveObserver {
      center.removeObserver(appDidBecomeActiveObserver)
      self.appDidBecomeActiveObserver = nil
    }
    if let appDidResignActiveObserver {
      center.removeObserver(appDidResignActiveObserver)
      self.appDidResignActiveObserver = nil
    }
  }

  private func updateWindowFocusObservers() {
    guard observedWindow !== window else { return }
    removeWindowFocusObservers()

    guard let window else { return }
    observedWindow = window

    let center = NotificationCenter.default
    windowDidBecomeKeyObserver = center.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      self?.syncEmbeddedFocusState()
    }
    windowDidResignKeyObserver = center.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      self?.syncEmbeddedFocusState()
    }
  }

  private func removeWindowFocusObservers() {
    let center = NotificationCenter.default
    if let windowDidBecomeKeyObserver {
      center.removeObserver(windowDidBecomeKeyObserver)
      self.windowDidBecomeKeyObserver = nil
    }
    if let windowDidResignKeyObserver {
      center.removeObserver(windowDidResignKeyObserver)
      self.windowDidResignKeyObserver = nil
    }
    observedWindow = nil
  }

  private func syncEmbeddedFocusState() {
    guard let app else { return }

    let appFocused = NSApp.isActive
    ghostty_app_set_focus(app, appFocused)

    guard let surface else { return }
    let surfaceFocused =
      appFocused
      && (window?.isKeyWindow ?? false)
      && (window?.firstResponder === self)
    ghostty_surface_set_focus(surface, surfaceFocused)
  }

  private func reloadGhosttyConfiguration() {
    guard let app, let surface else { return }
    guard let newConfig = loadGhosttyConfiguration() else {
      showMessage("Ghostty failed to reload terminal configuration.")
      return
    }

    ghostty_app_update_config(app, newConfig)
    ghostty_surface_update_config(surface, newConfig)

    if let config {
      ghostty_config_free(config)
    }
    config = newConfig
  }

  private func loadGhosttyConfiguration() -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }

    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)

    if !ghosttyConfigurationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let fileURL = Self.inlineConfigurationFileURL()
      do {
        try ghosttyConfigurationText.write(to: fileURL, atomically: true, encoding: .utf8)
      } catch {
        ghostty_config_free(config)
        return nil
      }

      fileURL.path.withCString { pathPointer in
        ghostty_config_load_file(config, pathPointer)
      }
    }

    ghostty_config_finalize(config)
    return config
  }

  private static func inlineConfigurationFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("argon-ghostty-inline.conf", isDirectory: false)
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

  private func handleAttention(_ event: TerminalAttentionEvent) {
    if onAttention == nil, case .bell = event {
      NSSound.beep()
    }
    onAttention?(event)
  }

  private func handleTitleChange(_ event: TerminalTitleChange) {
    onTitleChange?(event)
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
    GhosttyAppShortcutPassthrough.shouldPassThrough(
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      modifierFlags: event.modifierFlags
    )
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
    if let event = attentionEvent(from: action) {
      let userdataBox = UnsafeRawPointerBox(value: userdata(from: app, target: target))
      MainActorDispatch.async {
        guard let host = host(from: userdataBox.value) else { return }
        host.handleAttention(event)
      }
      return true
    }

    guard let event = titleChange(from: action) else { return false }
    let userdataBox = UnsafeRawPointerBox(value: userdata(from: app, target: target))
    MainActorDispatch.async {
      guard let host = host(from: userdataBox.value) else { return }
      host.handleTitleChange(event)
    }
    return true
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

  nonisolated private static func userdata(from app: ghostty_app_t, target: ghostty_target_s)
    -> UnsafeMutableRawPointer?
  {
    switch target.tag {
    case GHOSTTY_TARGET_SURFACE:
      guard let surface = target.target.surface else { return nil }
      return ghostty_surface_userdata(surface)
    case GHOSTTY_TARGET_APP:
      return ghostty_app_userdata(app)
    default:
      return nil
    }
  }

  nonisolated private static func attentionEvent(from action: ghostty_action_s)
    -> TerminalAttentionEvent?
  {
    switch action.tag {
    case GHOSTTY_ACTION_RING_BELL:
      return .bell
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let title =
        action.action.desktop_notification.title.flatMap {
          String(cString: $0, encoding: .utf8)
        } ?? ""
      let body =
        action.action.desktop_notification.body.flatMap {
          String(cString: $0, encoding: .utf8)
        } ?? ""
      return .desktopNotification(title: title, body: body)
    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let rawExitCode = Int(action.action.command_finished.exit_code)
      let exitCode = rawExitCode >= 0 ? rawExitCode : nil
      return .commandFinished(
        exitCode: exitCode,
        durationNanoseconds: action.action.command_finished.duration
      )
    default:
      return nil
    }
  }

  nonisolated private static func titleChange(from action: ghostty_action_s)
    -> TerminalTitleChange?
  {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
      return .window(actionString(action.action.set_title.title))
    case GHOSTTY_ACTION_SET_TAB_TITLE:
      return .tab(actionString(action.action.set_tab_title.title))
    default:
      return nil
    }
  }

  nonisolated private static func actionString(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.flatMap { String(cString: $0, encoding: .utf8) } ?? ""
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
