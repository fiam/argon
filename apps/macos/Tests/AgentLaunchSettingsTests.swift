import Foundation
import Testing

@testable import Argon

@Suite("AgentLaunchSettings")
struct AgentLaunchSettingsTests {
  @Test("launch mode defaults preserve existing behavior")
  func launchModeDefaultsPreserveExistingBehavior() {
    let suiteName = "AgentLaunchSettingsTests.default.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    #expect(AgentLaunchSettings.isDefaultYoloModeEnabled(userDefaults: defaults))
    #expect(AgentLaunchSettings.isDefaultSandboxEnabled(userDefaults: defaults))

    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("launch mode defaults can be disabled independently")
  func launchModeDefaultsCanBeDisabledIndependently() {
    let suiteName = "AgentLaunchSettingsTests.override.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    AgentLaunchSettings.setDefaultYoloModeEnabled(false, userDefaults: defaults)
    #expect(!AgentLaunchSettings.isDefaultYoloModeEnabled(userDefaults: defaults))
    #expect(AgentLaunchSettings.isDefaultSandboxEnabled(userDefaults: defaults))

    AgentLaunchSettings.setDefaultSandboxEnabled(false, userDefaults: defaults)
    #expect(!AgentLaunchSettings.isDefaultYoloModeEnabled(userDefaults: defaults))
    #expect(!AgentLaunchSettings.isDefaultSandboxEnabled(userDefaults: defaults))

    defaults.removePersistentDomain(forName: suiteName)
  }
}
