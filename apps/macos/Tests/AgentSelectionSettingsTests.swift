import Foundation
import Testing

@testable import Argon

@Suite("AgentSelectionSettings")
struct AgentSelectionSettingsTests {
  @Test("remembering the last selected agent is enabled by default")
  func rememberingLastSelectionIsEnabledByDefault() {
    let suiteName = "AgentSelectionSettingsTests.default.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    #expect(AgentSelectionSettings.rememberLastSelection(userDefaults: defaults))

    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("recording the last selected agent respects the preference")
  func recordingLastSelectionRespectsThePreference() {
    let suiteName = "AgentSelectionSettingsTests.record.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    AgentSelectionSettings.recordLastSelectedAgentID("codex", userDefaults: defaults)
    #expect(AgentSelectionSettings.lastSelectedAgentID(userDefaults: defaults) == "codex")

    AgentSelectionSettings.setRememberLastSelection(false, userDefaults: defaults)
    AgentSelectionSettings.recordLastSelectedAgentID("gemini", userDefaults: defaults)
    #expect(AgentSelectionSettings.lastSelectedAgentID(userDefaults: defaults) == "codex")

    defaults.removePersistentDomain(forName: suiteName)
  }

  @Test("preferred profile skips missing and unselectable remembered agents")
  @MainActor
  func preferredProfileSkipsMissingAndUnselectableRememberedAgents() {
    let suiteName = "AgentSelectionSettingsTests.preferred.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let profiles = SavedAgentProfiles.builtinDefaults

    AgentSelectionSettings.recordLastSelectedAgentID("codex", userDefaults: defaults)
    #expect(
      AgentSelectionSettings.preferredProfileID(
        in: profiles,
        userDefaults: defaults,
        isSelectable: { $0.id != "codex" }
      ) == nil
    )
    #expect(
      AgentSelectionSettings.preferredProfileID(
        in: profiles,
        userDefaults: defaults,
        isSelectable: { _ in true }
      ) == "codex"
    )

    AgentSelectionSettings.recordLastSelectedAgentID("missing", userDefaults: defaults)
    #expect(
      AgentSelectionSettings.preferredProfileID(
        in: profiles,
        userDefaults: defaults,
        isSelectable: { _ in true }
      ) == nil
    )

    defaults.removePersistentDomain(forName: suiteName)
  }
}
