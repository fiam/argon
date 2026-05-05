import Foundation

enum AppRuntimeMode: Equatable {
  case normal
  case appHostedUnitTests

  static let appHostedUnitTestsEnvironmentKey = "ARGON_APP_HOSTED_UNIT_TESTS"

  static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
    if isEnabled(environment[appHostedUnitTestsEnvironmentKey]) {
      return .appHostedUnitTests
    }

    return .normal
  }

  var suppressesVisibleAppHost: Bool {
    self == .appHostedUnitTests
  }

  private static func isEnabled(_ value: String?) -> Bool {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes":
      return true
    default:
      return false
    }
  }
}
