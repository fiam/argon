import Foundation

enum AppBundleVersion {
  static func displayVersion(bundle: Bundle = .main) -> String {
    displayVersion(infoDictionary: bundle.infoDictionary ?? [:])
  }

  static func versionIdentifier(bundle: Bundle = .main) -> String {
    let version = displayVersion(bundle: bundle)
    return version == "Unknown" ? "unknown" : version
  }

  static func displayVersion(infoDictionary: [String: Any]) -> String {
    if let shortVersion = trimmedValue(
      infoDictionary["CFBundleShortVersionString"]
    ) {
      return shortVersion
    }

    if let buildVersion = trimmedValue(infoDictionary["CFBundleVersion"]) {
      return buildVersion
    }

    return "Unknown"
  }

  private static func trimmedValue(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
