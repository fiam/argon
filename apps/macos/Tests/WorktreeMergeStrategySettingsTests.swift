import XCTest

@testable import Argon

final class WorktreeMergeStrategySettingsTests: XCTestCase {
  private var userDefaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "WorktreeMergeStrategySettingsTests.\(UUID().uuidString)"
    userDefaults = UserDefaults(suiteName: suiteName)
    userDefaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    userDefaults.removePersistentDomain(forName: suiteName)
    userDefaults = nil
    suiteName = nil
    super.tearDown()
  }

  func testStrategyFallsBackToDefaultForNewProjects() {
    userDefaults.set(
      WorktreeMergeStrategy.rebaseAndMerge.rawValue,
      forKey: WorktreeMergeStrategySettings.defaultStrategyStorageKey
    )

    XCTAssertEqual(
      WorktreeMergeStrategySettings.strategy(
        for: "/tmp/repo",
        userDefaults: userDefaults
      ),
      .rebaseAndMerge
    )
  }

  func testSetStrategyPersistsPerNormalizedRepoRoot() {
    WorktreeMergeStrategySettings.setStrategy(
      .squashAndMerge,
      for: "/tmp/repo/../repo",
      userDefaults: userDefaults
    )

    XCTAssertEqual(
      WorktreeMergeStrategySettings.strategy(
        for: "/tmp/repo",
        userDefaults: userDefaults
      ),
      .squashAndMerge
    )
  }
}
