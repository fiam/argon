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
  func recentProjectsPersistThroughReload() {
    let suiteName = "RecentProjectsTests.persistence"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    do {
      let recents = RecentProjects(userDefaults: defaults, storageKey: suiteName)
      recents.add(repoRoot: "/tmp/one")
      recents.add(repoRoot: "/tmp/two")
    }

    let reloaded = RecentProjects(userDefaults: defaults, storageKey: suiteName)
    #expect(reloaded.projects.map(\.repoRoot) == ["/tmp/two", "/tmp/one"])
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
