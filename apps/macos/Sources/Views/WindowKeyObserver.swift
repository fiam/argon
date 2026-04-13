import AppKit
import SwiftUI

@MainActor
struct WindowKeyObserver: NSViewRepresentable {
  typealias NSViewType = ObserverView

  let onBecomeKey: () -> Void
  let onResignKey: () -> Void
  var onWindowChange: ((NSWindow?) -> Void)? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(onBecomeKey: onBecomeKey, onResignKey: onResignKey)
  }

  func makeNSView(context: Context) -> ObserverView {
    let view = ObserverView(frame: .zero)
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ nsView: ObserverView, context: Context) {
    context.coordinator.onBecomeKey = onBecomeKey
    context.coordinator.onResignKey = onResignKey
    context.coordinator.onWindowChange = onWindowChange
    nsView.coordinator = context.coordinator
    context.coordinator.attach(to: nsView.window)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.detach()
  }

  @MainActor
  final class Coordinator {
    var onBecomeKey: () -> Void
    var onResignKey: () -> Void
    var onWindowChange: ((NSWindow?) -> Void)?

    private weak var window: NSWindow?
    private var didBecomeObserver: NSObjectProtocol?
    private var didResignObserver: NSObjectProtocol?

    init(onBecomeKey: @escaping () -> Void, onResignKey: @escaping () -> Void) {
      self.onBecomeKey = onBecomeKey
      self.onResignKey = onResignKey
    }

    func attach(to window: NSWindow?) {
      guard self.window !== window else { return }

      detach(notifyWindowChange: false)
      self.window = window
      onWindowChange?(window)

      guard let window else { return }

      let center = NotificationCenter.default
      didBecomeObserver = center.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.onBecomeKey()
        }
      }

      didResignObserver = center.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.onResignKey()
        }
      }

      if window.isKeyWindow {
        onBecomeKey()
      }
    }

    func detach(notifyWindowChange: Bool = true) {
      let center = NotificationCenter.default
      if let didBecomeObserver {
        center.removeObserver(didBecomeObserver)
      }
      if let didResignObserver {
        center.removeObserver(didResignObserver)
      }
      didBecomeObserver = nil
      didResignObserver = nil
      window = nil
      if notifyWindowChange {
        onWindowChange?(nil)
      }
    }
  }

  final class ObserverView: NSView {
    weak var coordinator: Coordinator?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      coordinator?.attach(to: window)
    }
  }
}
