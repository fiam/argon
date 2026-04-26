import AppIntents
import Foundation

enum AppIntentsMetadataDependency {
  static let appIntentProtocolName = String(reflecting: (any AppIntent).self)
}
