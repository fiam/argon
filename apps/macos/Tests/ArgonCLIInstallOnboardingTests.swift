import Foundation
import Testing

@testable import Argon

@Suite("ArgonCLIInstallOnboarding")
struct ArgonCLIInstallOnboardingTests {
  @Test("current onboarding is shown for a missing link")
  func currentOnboardingIsShownForAMissingLink() {
    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon.app/Contents/Helpers/argon",
      state: .missing
    )

    let onboarding = ArgonCLIInstallOnboarding.current(status: status)

    #expect(onboarding?.title == "Install Argon Command Line Tool")
    #expect(onboarding?.buttonTitle == "Install")
    #expect(onboarding?.detail.contains("`argon <dir>`") == true)
    #expect(onboarding?.detail.contains("`argon review <dir>`") == true)
    #expect(onboarding?.detail.contains("/usr/local/bin/argon") == false)
    #expect(
      onboarding?.toastMessage
        == "The command line tool is not installed. Install it to launch Argon from Terminal.")
  }

  @Test("current onboarding is shown for broken links")
  func currentOnboardingIsShownForBrokenLinks() {
    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon 2.app/Contents/Helpers/argon",
      state: .pointsElsewhere(currentTarget: "/Applications/Argon.app/Contents/Helpers/argon")
    )

    let onboarding = ArgonCLIInstallOnboarding.current(status: status)

    #expect(onboarding?.title == "Repair Argon Command Line Tool")
    #expect(onboarding?.buttonTitle == "Repair")
    #expect(onboarding?.detail.contains("looks out of date or broken") == true)
    #expect(onboarding?.detail.contains("`argon review <dir>`") == true)
    #expect(onboarding?.detail.contains("/Applications/Argon.app") == false)
    #expect(
      onboarding?.toastMessage
        == "The command line tool needs repair before it can launch Argon from Terminal.")
  }

  @Test("current onboarding is omitted for healthy or unavailable states")
  func currentOnboardingIsOmittedForHealthyOrUnavailableStates() {
    let installedStatus = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon.app/Contents/Helpers/argon",
      state: .installed
    )
    let unavailableStatus = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: nil,
      state: .bundledCLIUnavailable
    )

    #expect(ArgonCLIInstallOnboarding.current(status: installedStatus) == nil)
    #expect(ArgonCLIInstallOnboarding.current(status: unavailableStatus) == nil)
  }

  @Test("forced onboarding is shown for healthy states")
  func forcedOnboardingIsShownForHealthyStates() {
    let installedStatus = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon.app/Contents/Helpers/argon",
      state: .installed
    )

    let onboarding = ArgonCLIInstallOnboarding.current(status: installedStatus, forceShow: true)

    #expect(onboarding?.title == "Argon Command Line Tool")
    #expect(onboarding?.buttonTitle == "Installed")
    #expect(onboarding?.toastMessage == "Argon’s command line tool is installed.")
  }
}
