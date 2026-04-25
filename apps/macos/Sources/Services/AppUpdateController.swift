import Combine
import Foundation
import Sparkle

struct AppUpdateConfiguration: Equatable {
  let feedURL: URL?
  let publicEDKey: String?

  init(bundle: Bundle = .main) {
    self.init(infoDictionary: bundle.infoDictionary ?? [:])
  }

  init(infoDictionary: [String: Any]) {
    self.feedURL = AppUpdateConfiguration.urlValue(
      forKey: "SUFeedURL",
      in: infoDictionary
    )
    self.publicEDKey = AppUpdateConfiguration.stringValue(
      forKey: "SUPublicEDKey",
      in: infoDictionary
    )
  }

  var isConfigured: Bool {
    feedURL != nil && publicEDKey != nil
  }

  private static func stringValue(
    forKey key: String,
    in infoDictionary: [String: Any]
  ) -> String? {
    guard let value = infoDictionary[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func urlValue(
    forKey key: String,
    in infoDictionary: [String: Any]
  ) -> URL? {
    guard let string = stringValue(forKey: key, in: infoDictionary) else { return nil }
    guard let components = URLComponents(string: string) else { return nil }
    guard let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
      return nil
    }
    guard components.host?.isEmpty == false else { return nil }
    return components.url
  }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject {
  let configuration: AppUpdateConfiguration
  let currentVersion: String

  @Published private(set) var canCheckForUpdates = false

  private let updaterController: SPUStandardUpdaterController?
  private var canCheckForUpdatesCancellable: AnyCancellable?

  init(bundle: Bundle = .main) {
    self.configuration = AppUpdateConfiguration(bundle: bundle)
    self.currentVersion =
      (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"

    if configuration.isConfigured {
      let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
      )
      self.updaterController = updaterController
      self.canCheckForUpdates = updaterController.updater.canCheckForUpdates
      super.init()

      self.canCheckForUpdatesCancellable = updaterController.updater.publisher(
        for: \.canCheckForUpdates
      )
      .sink { [weak self] canCheckForUpdates in
        self?.canCheckForUpdates = canCheckForUpdates
      }

      updaterController.startUpdater()
    } else {
      self.updaterController = nil
      super.init()
    }
  }

  var statusText: String {
    if configuration.isConfigured {
      return "Automatic updates are enabled for this build."
    }
    return "Automatic updates are not configured for this build yet."
  }

  func checkForUpdates() {
    guard let updaterController else { return }
    updaterController.checkForUpdates(nil)
  }
}
