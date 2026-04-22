import Foundation
import Testing

@testable import Argon

@Suite("AppUpdateController")
struct AppUpdateControllerTests {
  @Test("configuration accepts a non-empty feed URL")
  func configurationAcceptsANonEmptyFeedURL() {
    let configuration = AppUpdateConfiguration(
      infoDictionary: [
        "SUFeedURL": "https://example.com/appcast.xml",
        "SUPublicEDKey": "abc123",
      ]
    )

    #expect(configuration.feedURL?.absoluteString == "https://example.com/appcast.xml")
    #expect(configuration.publicEDKey == "abc123")
    #expect(configuration.isConfigured)
  }

  @Test("configuration ignores blank Sparkle values")
  func configurationIgnoresBlankSparkleValues() {
    let configuration = AppUpdateConfiguration(
      infoDictionary: [
        "SUFeedURL": "   ",
        "SUPublicEDKey": "\n",
      ]
    )

    #expect(configuration.feedURL == nil)
    #expect(configuration.publicEDKey == nil)
    #expect(!configuration.isConfigured)
  }

  @Test("configuration ignores invalid feed URLs")
  func configurationIgnoresInvalidFeedURLs() {
    let configuration = AppUpdateConfiguration(
      infoDictionary: [
        "SUFeedURL": "not a url"
      ]
    )

    #expect(configuration.feedURL == nil)
    #expect(!configuration.isConfigured)
  }
}
