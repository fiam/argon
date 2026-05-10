import Foundation
import Testing

@testable import Argon

@Suite("WelcomeTips")
struct WelcomeTipsTests {
  @Test("tip rotator advances and wraps")
  func tipRotatorAdvancesAndWraps() throws {
    let suiteName = "WelcomeTipsTests.rotation.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let tips = [
      WelcomeTip(id: "one", title: "One", message: "First"),
      WelcomeTip(id: "two", title: "Two", message: "Second"),
    ]
    let rotator = WelcomeTipRotator(
      userDefaults: defaults,
      storageKey: "tip-index",
      tips: tips
    )

    #expect(rotator.nextTip()?.id == "one")
    #expect(rotator.nextTip()?.id == "two")
    #expect(rotator.nextTip()?.id == "one")
    #expect(defaults.integer(forKey: "tip-index") == 1)
  }

  @Test("tip rotator returns nil without tips")
  func tipRotatorReturnsNilWithoutTips() throws {
    let suiteName = "WelcomeTipsTests.empty.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let rotator = WelcomeTipRotator(
      userDefaults: defaults,
      storageKey: "tip-index",
      tips: []
    )

    #expect(rotator.nextTip() == nil)
    #expect(defaults.object(forKey: "tip-index") == nil)
  }
}
