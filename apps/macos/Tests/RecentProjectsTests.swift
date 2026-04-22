import Foundation
import Testing

@testable import Argon

@Suite("RecentProjects")
struct RecentProjectsTests {

  @Test("adding a recent project moves it to the front without duplication")
  @MainActor
  func addingARecentProjectMovesItToTheFrontWithoutDuplication() {
    let suiteName = "RecentProjectsTests.adding"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let recents = RecentProjects(userDefaults: defaults, storageKey: suiteName)

    recents.add(repoRoot: "/tmp/one")
    recents.add(repoRoot: "/tmp/two")
    recents.add(repoRoot: "/tmp/one")

    #expect(recents.projects.map(\.repoRoot) == ["/tmp/one", "/tmp/two"])
  }

  @Test("recent projects persist through reload")
  @MainActor
  func recentProjectsPersistThroughReload() throws {
    let suiteName = "RecentProjectsTests.persistence"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("RecentProjectsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }

    let one = fixtureRoot.appendingPathComponent("one")
    let two = fixtureRoot.appendingPathComponent("two")
    try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)

    do {
      let recents = RecentProjects(userDefaults: defaults, storageKey: suiteName)
      recents.add(repoRoot: one.path)
      recents.add(repoRoot: two.path)
    }

    let reloaded = RecentProjects(userDefaults: defaults, storageKey: suiteName)
    #expect(reloaded.projects.map(\.repoRoot) == [two.path, one.path])
  }

  @Test("missing recent projects are pruned on load")
  @MainActor
  func missingRecentProjectsArePrunedOnLoad() throws {
    let suiteName = "RecentProjectsTests.pruneOnLoad"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("RecentProjectsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }

    let existingRepo = fixtureRoot.appendingPathComponent("existing").path
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: existingRepo),
      withIntermediateDirectories: true
    )

    let missingRepo = fixtureRoot.appendingPathComponent("missing").path

    let encoder = JSONEncoder()
    let seeded = [
      RecentProject(repoRoot: existingRepo, repoName: "existing", lastOpened: .distantPast),
      RecentProject(repoRoot: missingRepo, repoName: "missing", lastOpened: .distantPast),
    ]
    defaults.set(try encoder.encode(seeded), forKey: suiteName)

    let reloaded = RecentProjects(userDefaults: defaults, storageKey: suiteName)

    #expect(reloaded.projects.map(\.repoRoot) == [existingRepo])
  }

  @Test("pruneMissingProjects removes stale entries after initialization")
  @MainActor
  func pruneMissingProjectsRemovesStaleEntriesAfterInitialization() throws {
    let suiteName = "RecentProjectsTests.pruneAfterInit"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("RecentProjectsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }

    let repo = fixtureRoot.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    let recents = RecentProjects(userDefaults: defaults, storageKey: suiteName)
    recents.add(repoRoot: repo.path)
    try FileManager.default.removeItem(at: repo)

    recents.pruneMissingProjects()

    #expect(recents.projects.isEmpty)
  }

  @Test("open recent menu titles include the full path for duplicate repo names")
  func openRecentMenuTitlesIncludeTheFullPathForDuplicateRepoNames() {
    let items = OpenRecentMenuItemBuilder.menuItems(
      from: [
        RecentProject(
          repoRoot: "/tmp/one/argon",
          repoName: "argon",
          lastOpened: .distantPast
        ),
        RecentProject(
          repoRoot: "/tmp/two/argon",
          repoName: "argon",
          lastOpened: .distantPast
        ),
        RecentProject(
          repoRoot: "/tmp/slotracer",
          repoName: "slotracer",
          lastOpened: .distantPast
        ),
      ])

    #expect(
      items == [
        OpenRecentMenuItem(
          repoRoot: "/tmp/one/argon",
          menuTitle: "argon — /tmp/one/argon"
        ),
        OpenRecentMenuItem(
          repoRoot: "/tmp/two/argon",
          menuTitle: "argon — /tmp/two/argon"
        ),
        OpenRecentMenuItem(
          repoRoot: "/tmp/slotracer",
          menuTitle: "slotracer"
        ),
      ])
  }
}
