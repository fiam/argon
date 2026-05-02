import Foundation

enum AgentTerminalPersistenceExperimentSettings {
  static let enabledStorageKey = "experimentalPersistentAgentTerminalsEnabled"
  static let defaultEnabled = false

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledStorageKey) as? Bool ?? defaultEnabled
  }

  static var canUseTerminalSessionPersistence: Bool {
    isEnabled && TerminalSessionBackends.isAvailable()
  }
}
