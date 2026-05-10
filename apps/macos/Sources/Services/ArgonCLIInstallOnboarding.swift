import Foundation

struct ArgonCLIInstallOnboarding: Equatable, Sendable {
  static let dismissalStorageKey = "cliInstallOnboardingDismissedTargetPath"
  static let versionDismissalStorageKey = "cliInstallOnboardingDismissedAppVersion"

  let status: ArgonCLIInstallLinkStatus

  static func current(status: ArgonCLIInstallLinkStatus, forceShow: Bool = false) -> Self? {
    if forceShow {
      return Self(status: status)
    }

    guard status.canRepair, status.expectedTargetPath != nil else {
      return nil
    }
    return Self(status: status)
  }

  var buttonTitle: String {
    status.repairButtonTitle
  }

  var toastMessage: String {
    switch status.state {
    case .missing:
      return
        "The command line tool is not installed. Install it to launch Argon from Terminal."
    case .pointsElsewhere, .occupiedByFile:
      return
        "The command line tool needs repair before it can launch Argon from Terminal."
    case .installed, .bundledCLIUnavailable:
      return status.detail
    }
  }
}
