import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ArgonCLIInstallStartupPrompt {
  static let forceShowEnvironmentKey = "ARGON_FORCE_CLI_INSTALL_TOAST"
  private static let disableEnvironmentKey = "ARGON_UI_TEST_DISABLE_CLI_INSTALL_PROMPT"

  private(set) var currentOnboarding: ArgonCLIInstallOnboarding?
  private(set) var errorMessage: String?
  private(set) var isRepairing = false

  private let userDefaults: UserDefaults
  private let statusProvider: @MainActor @Sendable () -> ArgonCLIInstallLinkStatus
  private let repairAction: @MainActor @Sendable () throws -> ArgonCLIInstallLinkStatus
  private let environmentProvider: @MainActor @Sendable () -> [String: String]
  private let appVersionProvider: @MainActor @Sendable () -> String
  private var activePresentationID: UUID?
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
    environmentProvider: @escaping @MainActor @Sendable () -> [String: String] = {
      ProcessInfo.processInfo.environment
    },
    appVersionProvider: @escaping @MainActor @Sendable () -> String = {
      ArgonCLIInstallStartupPrompt.currentAppVersionIdentifier()
    }
  ) {
    self.userDefaults = userDefaults
    self.statusProvider = statusProvider
    self.repairAction = repairAction
    self.environmentProvider = environmentProvider
    self.appVersionProvider = appVersionProvider
  }

  func presentIfNeeded(presentationID: UUID = UUID()) async {
    guard !didAttemptThisLaunch, !isPresenting else { return }
    guard !isDisabledForCurrentProcess else {
      didAttemptThisLaunch = true
      return
    }

    didAttemptThisLaunch = true

    let status = statusProvider()
    let appVersion = currentAppVersion
    migrateLegacyDismissalIfNeeded(status: status, appVersion: appVersion)
    guard shouldForceShowToast || dismissedAppVersion != appVersion else { return }
    guard
      let onboarding = ArgonCLIInstallOnboarding.current(
        status: status,
        forceShow: shouldForceShowToast
      )
    else { return }

    activePresentationID = presentationID
    currentOnboarding = onboarding
    errorMessage = nil
    isPresenting = true
  }

  func onboarding(for presentationID: UUID) -> ArgonCLIInstallOnboarding? {
    activePresentationID == presentationID ? currentOnboarding : nil
  }

  func dismissToast(for presentationID: UUID? = nil) {
    guard presentationID == nil || activePresentationID == presentationID else { return }
    clearToast()
  }

  func suppressUntilNextVersion(for presentationID: UUID? = nil) {
    guard presentationID == nil || activePresentationID == presentationID else { return }
    guard currentOnboarding != nil else { return }

    dismissedAppVersion = currentAppVersion
    dismissedTargetPath = nil
    clearToast()
  }

  func repairFromToast(for presentationID: UUID? = nil) async {
    guard presentationID == nil || activePresentationID == presentationID else { return }
    guard currentOnboarding?.status.canRepair == true, !isRepairing else { return }

    isRepairing = true
    defer { isRepairing = false }

    do {
      _ = try repairAction()
      dismissedTargetPath = nil
      dismissedAppVersion = nil
      clearToast()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func clearToast() {
    currentOnboarding = nil
    errorMessage = nil
    activePresentationID = nil
    isPresenting = false
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

  private var dismissedAppVersion: String? {
    get {
      let value = userDefaults.string(forKey: ArgonCLIInstallOnboarding.versionDismissalStorageKey)
      return value?.isEmpty == false ? value : nil
    }
    set {
      if let newValue, !newValue.isEmpty {
        userDefaults.set(newValue, forKey: ArgonCLIInstallOnboarding.versionDismissalStorageKey)
      } else {
        userDefaults.removeObject(forKey: ArgonCLIInstallOnboarding.versionDismissalStorageKey)
      }
    }
  }

  private var currentAppVersion: String {
    let version = appVersionProvider()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return version.isEmpty ? "unknown" : version
  }

  private func migrateLegacyDismissalIfNeeded(
    status: ArgonCLIInstallLinkStatus,
    appVersion: String
  ) {
    guard let expectedTargetPath = status.expectedTargetPath else { return }
    guard dismissedTargetPath == expectedTargetPath else { return }

    dismissedAppVersion = appVersion
    dismissedTargetPath = nil
  }

  private var isDisabledForCurrentProcess: Bool {
    Self.parseBool(environmentProvider()[Self.disableEnvironmentKey])
  }

  private var shouldForceShowToast: Bool {
    Self.parseBool(environmentProvider()[Self.forceShowEnvironmentKey])
  }

  private static func parseBool(_ value: String?) -> Bool {
    let normalizedValue = value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return switch normalizedValue {
    case "1", "true", "yes", "on":
      true
    default:
      false
    }
  }

  private static func currentAppVersionIdentifier(bundle: Bundle = .main) -> String {
    AppBundleVersion.versionIdentifier(bundle: bundle)
  }
}

extension View {
  func argonCLIInstallStartupToast(
    _ prompt: ArgonCLIInstallStartupPrompt,
    isEnabled: Bool = true
  ) -> some View {
    modifier(ArgonCLIInstallStartupToastModifier(prompt: prompt, isEnabled: isEnabled))
  }
}

private struct ArgonCLIInstallStartupToastModifier: ViewModifier {
  let prompt: ArgonCLIInstallStartupPrompt
  let isEnabled: Bool
  @State private var presentationID = UUID()

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottomTrailing) {
        if let onboarding = prompt.onboarding(for: presentationID) {
          ArgonCLIInstallStartupToastView(
            onboarding: onboarding,
            errorMessage: prompt.errorMessage,
            isRepairing: prompt.isRepairing,
            onRepair: {
              Task {
                await prompt.repairFromToast(for: presentationID)
              }
            },
            onSuppress: {
              prompt.suppressUntilNextVersion(for: presentationID)
            },
            onDismiss: {
              prompt.dismissToast(for: presentationID)
            }
          )
          .padding(.trailing, 18)
          .padding(.bottom, 18)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(
        .easeInOut(duration: 0.18),
        value: prompt.onboarding(for: presentationID) != nil
      )
      .task {
        guard isEnabled else { return }
        await prompt.presentIfNeeded(presentationID: presentationID)
      }
  }
}

private struct ArgonCLIInstallStartupToastView: View {
  let onboarding: ArgonCLIInstallOnboarding
  let errorMessage: String?
  let isRepairing: Bool
  let onRepair: () -> Void
  let onSuppress: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "terminal.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.orange)
        .frame(width: 18, height: 22)

      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 8) {
          Text("Command Line Tool")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)

          Spacer(minLength: 8)

          Button(action: onDismiss) {
            Image(systemName: "xmark")
              .font(.system(size: 11, weight: .semibold))
              .frame(width: 18, height: 18)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Dismiss")
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(onboarding.toastMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if let errorMessage {
            Text(errorMessage)
              .font(.caption2)
              .foregroundStyle(.red)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        HStack(spacing: 8) {
          Spacer(minLength: 0)

          if onboarding.status.canRepair {
            Button("Don't Install") {
              onSuppress()
            }
            .controlSize(.small)
            .accessibilityIdentifier("cli-install-startup-toast-suppress-button")
          }

          if isRepairing {
            ProgressView()
              .controlSize(.small)
              .frame(width: 44, height: 22)
          } else {
            Button(onboarding.buttonTitle) {
              onRepair()
            }
            .controlSize(.small)
            .disabled(!onboarding.status.canRepair)
            .accessibilityIdentifier("cli-install-startup-toast-repair-button")
          }
        }
      }
    }
    .padding(12)
    .frame(width: 380, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("cli-install-startup-toast")
  }
}
