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

  var title: String {
    switch status.state {
    case .missing:
      return "Install Argon Command Line Tool"
    case .pointsElsewhere, .occupiedByFile:
      return "Repair Argon Command Line Tool"
    case .installed, .bundledCLIUnavailable:
      return "Argon Command Line Tool"
    }
  }

  var detail: String {
    let usage =
      "It enables `argon <dir>` to open a repository or worktree and `argon review <dir>` to open the review UI from Terminal, editors, and scripts."

    switch status.state {
    case .missing:
      return
        "Argon’s command line tool is not installed. \(usage) You can always manage this later in Settings > General."
    case .pointsElsewhere:
      return
        "Argon’s command line tool looks out of date or broken. \(usage) You can always manage this later in Settings > General."
    case .occupiedByFile:
      return
        "Argon’s command line tool looks out of date or broken. \(usage) You can always manage this later in Settings > General."
    case .installed, .bundledCLIUnavailable:
      return status.detail
    }
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
