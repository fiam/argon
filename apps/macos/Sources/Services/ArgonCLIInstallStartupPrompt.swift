import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ArgonCLIInstallStartupPrompt {
  enum Action: Sendable {
    case repair
    case notNow
  }

  struct Decision: Sendable {
    let action: Action
    let suppressFuturePrompts: Bool
  }

  struct Presenter {
    let present: @MainActor @Sendable (ArgonCLIInstallOnboarding) async -> Decision
    let presentError: @MainActor @Sendable (String) async -> Void

    static let live = Self(
      present: { onboarding in
        if let window = await presentationWindow() {
          return await presentSheet(onboarding: onboarding, parentWindow: window)
        }

        return await presentSheet(onboarding: onboarding, parentWindow: nil)
      },
      presentError: { message in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Install the Argon Command Line Tool"
        alert.informativeText = message
        alert.runModal()
      }
    )

    @MainActor
    private static func presentationWindow() async -> NSWindow? {
      for _ in 0..<20 {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow
          ?? NSApp.windows.first(where: \.isVisible)
        {
          return window
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return nil
    }

    @MainActor
    private static func presentSheet(
      onboarding: ArgonCLIInstallOnboarding,
      parentWindow: NSWindow?
    ) async -> Decision {
      await withCheckedContinuation { continuation in
        final class DecisionBox {
          var continuation: CheckedContinuation<Decision, Never>?
          var decision: Decision?
        }

        let box = DecisionBox()
        box.continuation = continuation

        let hostingController = NSHostingController(
          rootView: ArgonCLIInstallStartupPromptSheetView(onboarding: onboarding) { decision in
            box.decision = decision
          }
        )

        let sheet = NSPanel(
          contentRect: NSRect(x: 0, y: 0, width: 540, height: 260),
          styleMask: [.titled, .fullSizeContentView],
          backing: .buffered,
          defer: false
        )
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.isMovable = false
        sheet.isReleasedWhenClosed = false
        sheet.standardWindowButton(.closeButton)?.isHidden = true
        sheet.standardWindowButton(.miniaturizeButton)?.isHidden = true
        sheet.standardWindowButton(.zoomButton)?.isHidden = true
        sheet.contentViewController = hostingController
        sheet.contentMinSize = NSSize(width: 540, height: 260)
        sheet.contentMaxSize = NSSize(width: 540, height: 260)
        sheet.center()

        let finish: (Decision) -> Void = { decision in
          guard let continuation = box.continuation else { return }
          box.continuation = nil
          continuation.resume(returning: decision)
        }

        hostingController.rootView = ArgonCLIInstallStartupPromptSheetView(onboarding: onboarding) {
          decision in
          if let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: .OK)
          } else {
            NSApp.stopModal()
            sheet.orderOut(nil)
          }
          finish(decision)
        }

        if let parentWindow {
          parentWindow.beginSheet(sheet)
        } else {
          NSApp.activate(ignoringOtherApps: true)
          sheet.makeKeyAndOrderFront(nil)
          NSApp.runModal(for: sheet)
          if let decision = box.decision {
            finish(decision)
          } else {
            let fallback = Decision(action: .notNow, suppressFuturePrompts: false)
            finish(fallback)
          }
        }
      }
    }
  }

  private let userDefaults: UserDefaults
  private let statusProvider: @MainActor @Sendable () -> ArgonCLIInstallLinkStatus
  private let repairAction: @MainActor @Sendable () throws -> ArgonCLIInstallLinkStatus
  private let presenter: Presenter
  private var didAttemptThisLaunch = false
  private var isPresenting = false

  init(
    userDefaults: UserDefaults = .standard,
    statusProvider: @escaping @MainActor @Sendable () -> ArgonCLIInstallLinkStatus = {
      ArgonCLIInstallLink.status()
    },
    repairAction: @escaping @MainActor @Sendable () throws -> ArgonCLIInstallLinkStatus = {
      try ArgonCLIInstallLink.repair()
    },
    presenter: Presenter = .live
  ) {
    self.userDefaults = userDefaults
    self.statusProvider = statusProvider
    self.repairAction = repairAction
    self.presenter = presenter
  }

  func presentIfNeeded() async {
    guard !didAttemptThisLaunch, !isPresenting else { return }

    let status = statusProvider()
    guard
      let onboarding = ArgonCLIInstallOnboarding.current(
        status: status,
        dismissedTargetPath: dismissedTargetPath
      )
    else {
      didAttemptThisLaunch = true
      return
    }

    isPresenting = true
    defer {
      isPresenting = false
      didAttemptThisLaunch = true
    }

    let decision = await presenter.present(onboarding)

    switch decision.action {
    case .repair:
      do {
        _ = try repairAction()
        dismissedTargetPath = nil
      } catch {
        await presenter.presentError(error.localizedDescription)
      }
    case .notNow:
      if decision.suppressFuturePrompts {
        dismissedTargetPath = status.expectedTargetPath
      }
    }
  }

  private var dismissedTargetPath: String? {
    get {
      let value = userDefaults.string(forKey: ArgonCLIInstallOnboarding.dismissalStorageKey)
      return value?.isEmpty == false ? value : nil
    }
    set {
      if let newValue, !newValue.isEmpty {
        userDefaults.set(newValue, forKey: ArgonCLIInstallOnboarding.dismissalStorageKey)
      } else {
        userDefaults.removeObject(forKey: ArgonCLIInstallOnboarding.dismissalStorageKey)
      }
    }
  }
}

private struct ArgonCLIInstallStartupPromptSheetView: View {
  let onboarding: ArgonCLIInstallOnboarding
  let onDecision: (ArgonCLIInstallStartupPrompt.Decision) -> Void
  @State private var suppressFuturePrompts = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(onboarding.title)
        .font(.title3.weight(.semibold))

      Text(onboarding.detail)
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Toggle("Don’t ask again", isOn: $suppressFuturePrompts)
        .toggleStyle(.checkbox)

      HStack(spacing: 12) {
        Spacer()

        Button("Not Now") {
          onDecision(
            .init(action: .notNow, suppressFuturePrompts: suppressFuturePrompts)
          )
        }
        .keyboardShortcut(.cancelAction)

        Button(onboarding.buttonTitle) {
          onDecision(
            .init(action: .repair, suppressFuturePrompts: suppressFuturePrompts)
          )
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 540, alignment: .leading)
  }
}
