import Foundation
import Testing

@testable import Argon

@Suite("ArgonCLIInstallOnboarding")
struct ArgonCLIInstallOnboardingTests {
  @Test("current onboarding is shown for a missing link")
  func currentOnboardingIsShownForAMissingLink() {
    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon.app/Contents/Resources/bin/argon",
      state: .missing
    )

    let onboarding = ArgonCLIInstallOnboarding.current(
      status: status,
      dismissedTargetPath: nil
    )

    #expect(onboarding?.title == "Install Argon Command Line Tool")
    #expect(onboarding?.buttonTitle == "Install")
    #expect(onboarding?.detail.contains("`argon <dir>`") == true)
    #expect(onboarding?.detail.contains("`argon review <dir>`") == true)
    #expect(onboarding?.detail.contains("/usr/local/bin/argon") == false)
  }

  @Test("current onboarding is hidden after dismissing the same bundle target")
  func currentOnboardingIsHiddenAfterDismissingTheSameBundleTarget() {
    let targetPath = "/Applications/Argon.app/Contents/Resources/bin/argon"
    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: targetPath,
      state: .missing
    )

    let onboarding = ArgonCLIInstallOnboarding.current(
      status: status,
      dismissedTargetPath: targetPath
    )

    #expect(onboarding == nil)
  }

  @Test("current onboarding reappears when the bundled target changes")
  func currentOnboardingReappearsWhenTheBundledTargetChanges() {
    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon 2.app/Contents/Resources/bin/argon",
      state: .pointsElsewhere(currentTarget: "/Applications/Argon.app/Contents/Resources/bin/argon")
    )

    let onboarding = ArgonCLIInstallOnboarding.current(
      status: status,
      dismissedTargetPath: "/Applications/Argon.app/Contents/Resources/bin/argon"
    )

    #expect(onboarding?.title == "Repair Argon Command Line Tool")
    #expect(onboarding?.buttonTitle == "Repair")
    #expect(onboarding?.detail.contains("looks out of date or broken") == true)
    #expect(onboarding?.detail.contains("`argon review <dir>`") == true)
    #expect(onboarding?.detail.contains("/Applications/Argon.app") == false)
  }

  @Test("current onboarding is omitted for healthy or unavailable states")
  func currentOnboardingIsOmittedForHealthyOrUnavailableStates() {
    let installedStatus = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon.app/Contents/Resources/bin/argon",
      state: .installed
    )
    let unavailableStatus = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: nil,
      state: .bundledCLIUnavailable
    )

    #expect(
      ArgonCLIInstallOnboarding.current(status: installedStatus, dismissedTargetPath: nil) == nil)
    #expect(
      ArgonCLIInstallOnboarding.current(status: unavailableStatus, dismissedTargetPath: nil) == nil)
  }
}
