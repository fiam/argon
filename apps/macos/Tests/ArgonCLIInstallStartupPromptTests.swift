import Foundation
import Testing

@testable import Argon

@Suite("ArgonCLIInstallStartupPrompt")
@MainActor
struct ArgonCLIInstallStartupPromptTests {
  @Test("startup toast is shown on first run")
  func startupToastIsShownOnFirstRun() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.firstRun"
    let defaults = makeUserDefaults(suiteName: suiteName)
    let status = missingStatus()

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status }
    )

    await prompt.presentIfNeeded()

    #expect(prompt.currentOnboarding?.status == status)
  }

  @Test("toast dismissal is only launch-local")
  func toastDismissalIsOnlyLaunchLocal() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.dismiss"
    let defaults = makeUserDefaults(suiteName: suiteName)
    let status = missingStatus()

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status }
    )

    await prompt.presentIfNeeded()
    prompt.dismissToast()
    await prompt.presentIfNeeded()

    #expect(prompt.currentOnboarding == nil)
    #expect(defaults.string(forKey: ArgonCLIInstallOnboarding.dismissalStorageKey) == nil)

    let nextLaunchPrompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status }
    )

    await nextLaunchPrompt.presentIfNeeded()

    #expect(nextLaunchPrompt.currentOnboarding?.status == status)
  }

  @Test("legacy target dismissal is migrated to current app version")
  func legacyTargetDismissalIsMigratedToCurrentAppVersion() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.oldDismissal"
    let defaults = makeUserDefaults(suiteName: suiteName)
    let status = missingStatus()
    defaults.set(
      status.expectedTargetPath,
      forKey: ArgonCLIInstallOnboarding.dismissalStorageKey
    )

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      appVersionProvider: { "1.0.0" }
    )

    await prompt.presentIfNeeded()

    #expect(prompt.currentOnboarding == nil)
    #expect(defaults.string(forKey: ArgonCLIInstallOnboarding.dismissalStorageKey) == nil)
    #expect(
      defaults.string(forKey: ArgonCLIInstallOnboarding.versionDismissalStorageKey) == "1.0.0")

    let nextVersionPrompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      appVersionProvider: { "1.1.0" }
    )

    await nextVersionPrompt.presentIfNeeded()

    #expect(nextVersionPrompt.currentOnboarding?.status == status)
  }

  @Test("toast reappears when the bundled target changes")
  func toastReappearsWhenTheBundledTargetChanges() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.targetChange"
    let defaults = makeUserDefaults(suiteName: suiteName)
    defaults.set(
      "/Applications/Argon.app/Contents/Helpers/argon",
      forKey: ArgonCLIInstallOnboarding.dismissalStorageKey
    )

    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon 2.app/Contents/Helpers/argon",
      state: .pointsElsewhere(currentTarget: "/Applications/Argon.app/Contents/Helpers/argon")
    )

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status }
    )

    await prompt.presentIfNeeded()

    #expect(prompt.currentOnboarding?.status == status)
  }

  @Test("don't install suppresses the toast until the next app version")
  func dontInstallSuppressesTheToastUntilTheNextAppVersion() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.dontInstall"
    let defaults = makeUserDefaults(suiteName: suiteName)
    let status = missingStatus()

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      appVersionProvider: { "1.0.0" }
    )

    await prompt.presentIfNeeded()
    #expect(prompt.currentOnboarding?.status == status)

    prompt.suppressUntilNextVersion()

    #expect(prompt.currentOnboarding == nil)
    #expect(
      defaults.string(forKey: ArgonCLIInstallOnboarding.versionDismissalStorageKey) == "1.0.0")

    let sameVersionPrompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      appVersionProvider: { "1.0.0" }
    )

    await sameVersionPrompt.presentIfNeeded()

    #expect(sameVersionPrompt.currentOnboarding == nil)

    let nextVersionPrompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      appVersionProvider: { "1.1.0" }
    )

    await nextVersionPrompt.presentIfNeeded()

    #expect(nextVersionPrompt.currentOnboarding?.status == status)
  }

  @Test("startup toast can be forced despite current version suppression")
  func startupToastCanBeForcedDespiteCurrentVersionSuppression() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.forceSuppressedVersion"
    let defaults = makeUserDefaults(suiteName: suiteName)
    let status = missingStatus()
    defaults.set(
      "1.0.0",
      forKey: ArgonCLIInstallOnboarding.versionDismissalStorageKey
    )

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      environmentProvider: {
        [ArgonCLIInstallStartupPrompt.forceShowEnvironmentKey: "1"]
      },
      appVersionProvider: { "1.0.0" }
    )

    await prompt.presentIfNeeded()

    #expect(prompt.currentOnboarding?.status == status)
  }

  @Test("startup toast can be forced for an installed link")
  func startupToastCanBeForcedForAnInstalledLink() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.forceInstalled"
    let defaults = makeUserDefaults(suiteName: suiteName)
    let status = installedStatus()
    var repairCalls = 0

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: {
        repairCalls += 1
        return status
      },
      environmentProvider: {
        [ArgonCLIInstallStartupPrompt.forceShowEnvironmentKey: "1"]
      }
    )

    await prompt.presentIfNeeded()
    await prompt.repairFromToast()

    #expect(prompt.currentOnboarding?.status == status)
    #expect(repairCalls == 0)
  }

  @Test("repair clears dismissal and hides the toast on success")
  func repairClearsDismissalAndHidesTheToastOnSuccess() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.repair"
    let defaults = makeUserDefaults(suiteName: suiteName)

    let expectedTarget = "/Applications/Argon.app/Contents/Helpers/argon"
    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: expectedTarget,
      state: .missing
    )
    defaults.set(
      "/Applications/Argon Old.app/Contents/Helpers/argon",
      forKey: ArgonCLIInstallOnboarding.dismissalStorageKey
    )
    defaults.set(
      "0.9.0",
      forKey: ArgonCLIInstallOnboarding.versionDismissalStorageKey
    )

    var repairCalls = 0
    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: {
        repairCalls += 1
        return ArgonCLIInstallLinkStatus(
          linkPath: status.linkPath,
          expectedTargetPath: expectedTarget,
          state: .installed
        )
      },
      appVersionProvider: { "1.0.0" }
    )

    await prompt.presentIfNeeded()
    #expect(prompt.currentOnboarding?.status == status)

    await prompt.repairFromToast()

    #expect(repairCalls == 1)
    #expect(prompt.currentOnboarding == nil)
    #expect(prompt.errorMessage == nil)
    #expect(defaults.string(forKey: ArgonCLIInstallOnboarding.dismissalStorageKey) == nil)
    #expect(defaults.string(forKey: ArgonCLIInstallOnboarding.versionDismissalStorageKey) == nil)
  }

  @Test("toast stays suppressed when UI tests disable the startup prompt")
  func toastStaysSuppressedWhenUITestsDisableTheStartupPrompt() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.disabled"
    let defaults = makeUserDefaults(suiteName: suiteName)
    let status = missingStatus()

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      environmentProvider: {
        ["ARGON_UI_TEST_DISABLE_CLI_INSTALL_PROMPT": "1"]
      }
    )

    await prompt.presentIfNeeded()

    #expect(prompt.currentOnboarding == nil)
    #expect(prompt.errorMessage == nil)
  }

  private func makeUserDefaults(suiteName: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func missingStatus() -> ArgonCLIInstallLinkStatus {
    ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon.app/Contents/Helpers/argon",
      state: .missing
    )
  }

  private func installedStatus() -> ArgonCLIInstallLinkStatus {
    ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon.app/Contents/Helpers/argon",
      state: .installed
    )
  }
}
