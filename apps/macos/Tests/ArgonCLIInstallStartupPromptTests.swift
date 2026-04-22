import Foundation
import Testing

@testable import Argon

@Suite("ArgonCLIInstallStartupPrompt")
@MainActor
struct ArgonCLIInstallStartupPromptTests {
  final class Recorder {
    var prompts: [ArgonCLIInstallOnboarding] = []
    var errors: [String] = []
    var nextAction: ArgonCLIInstallStartupPrompt.Action = .notNow
    var suppressFuturePrompts = false
  }

  @Test("missing prompt only stays hidden when the user asks not to be prompted again")
  func missingPromptOnlyStaysHiddenWhenTheUserAsksNotToBePromptedAgain() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.dismiss"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let recorder = Recorder()
    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon.app/Contents/Resources/bin/argon",
      state: .missing
    )

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      presenter: .init(
        present: { onboarding in
          recorder.prompts.append(onboarding)
          return .init(
            action: recorder.nextAction,
            suppressFuturePrompts: recorder.suppressFuturePrompts
          )
        },
        presentError: { message in
          recorder.errors.append(message)
        }
      )
    )

    await prompt.presentIfNeeded()

    #expect(recorder.prompts.count == 1)
    #expect(defaults.string(forKey: ArgonCLIInstallOnboarding.dismissalStorageKey) == nil)

    let secondRecorder = Recorder()
    let secondPrompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      presenter: .init(
        present: { onboarding in
          secondRecorder.prompts.append(onboarding)
          return .init(
            action: secondRecorder.nextAction,
            suppressFuturePrompts: secondRecorder.suppressFuturePrompts
          )
        },
        presentError: { message in
          secondRecorder.errors.append(message)
        }
      )
    )

    await secondPrompt.presentIfNeeded()

    #expect(secondRecorder.prompts.count == 1)

    defaults.removePersistentDomain(forName: suiteName)

    let suppressedRecorder = Recorder()
    suppressedRecorder.suppressFuturePrompts = true
    let suppressedPrompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      presenter: .init(
        present: { onboarding in
          suppressedRecorder.prompts.append(onboarding)
          return .init(
            action: suppressedRecorder.nextAction,
            suppressFuturePrompts: suppressedRecorder.suppressFuturePrompts
          )
        },
        presentError: { message in
          suppressedRecorder.errors.append(message)
        }
      )
    )

    await suppressedPrompt.presentIfNeeded()

    #expect(
      defaults.string(forKey: ArgonCLIInstallOnboarding.dismissalStorageKey)
        == status.expectedTargetPath
    )
  }

  @Test("prompt reappears when the bundled target changes")
  func promptReappearsWhenTheBundledTargetChanges() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.targetChange"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(
      "/Applications/Argon.app/Contents/Resources/bin/argon",
      forKey: ArgonCLIInstallOnboarding.dismissalStorageKey
    )

    let recorder = Recorder()
    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: "/Applications/Argon 2.app/Contents/Resources/bin/argon",
      state: .pointsElsewhere(currentTarget: "/Applications/Argon.app/Contents/Resources/bin/argon")
    )

    let prompt = ArgonCLIInstallStartupPrompt(
      userDefaults: defaults,
      statusProvider: { status },
      repairAction: { status },
      presenter: .init(
        present: { onboarding in
          recorder.prompts.append(onboarding)
          return .init(
            action: recorder.nextAction,
            suppressFuturePrompts: recorder.suppressFuturePrompts
          )
        },
        presentError: { message in
          recorder.errors.append(message)
        }
      )
    )

    await prompt.presentIfNeeded()

    #expect(recorder.prompts.count == 1)
  }

  @Test("repair clears dismissal and does not present an error on success")
  func repairClearsDismissalAndDoesNotPresentAnErrorOnSuccess() async {
    let suiteName = "ArgonCLIInstallStartupPromptTests.repair"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let recorder = Recorder()
    recorder.nextAction = .repair

    let expectedTarget = "/Applications/Argon.app/Contents/Resources/bin/argon"
    let status = ArgonCLIInstallLinkStatus(
      linkPath: "/usr/local/bin/argon",
      expectedTargetPath: expectedTarget,
      state: .missing
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
      presenter: .init(
        present: { onboarding in
          recorder.prompts.append(onboarding)
          return .init(
            action: recorder.nextAction,
            suppressFuturePrompts: recorder.suppressFuturePrompts
          )
        },
        presentError: { message in
          recorder.errors.append(message)
        }
      )
    )

    await prompt.presentIfNeeded()

    #expect(repairCalls == 1)
    #expect(recorder.errors.isEmpty)
    #expect(defaults.string(forKey: ArgonCLIInstallOnboarding.dismissalStorageKey) == nil)
  }
}
