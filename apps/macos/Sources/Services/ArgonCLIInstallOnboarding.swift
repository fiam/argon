import Foundation

struct ArgonCLIInstallOnboarding: Equatable, Sendable {
  static let dismissalStorageKey = "cliInstallOnboardingDismissedTargetPath"

  let status: ArgonCLIInstallLinkStatus

  static func current(
    status: ArgonCLIInstallLinkStatus,
    dismissedTargetPath: String?
  ) -> Self? {
    guard status.canRepair, let expectedTargetPath = status.expectedTargetPath else {
      return nil
    }
    guard dismissedTargetPath != expectedTargetPath else {
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
}
