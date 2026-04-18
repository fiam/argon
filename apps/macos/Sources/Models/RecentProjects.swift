import Foundation

struct RecentProject: Codable, Identifiable, Hashable {
  var id: String { repoRoot }
  let repoRoot: String
  let repoName: String
  let lastOpened: Date
}

@MainActor
@Observable
final class RecentProjects {
  private static let defaultStorageKey = "recentProjects"
  private static let maxCount = 20

  private let userDefaults: UserDefaults
  private let storageKey: String
  var projects: [RecentProject] = []

  init(
    userDefaults: UserDefaults = .standard,
    storageKey: String = defaultStorageKey
  ) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
    load()
  }

  func add(repoRoot: String) {
    let name =
      URL(fileURLWithPath: repoRoot).lastPathComponent
    projects.removeAll { $0.repoRoot == repoRoot }
    projects.insert(
      RecentProject(repoRoot: repoRoot, repoName: name, lastOpened: Date()),
      at: 0
    )
    if projects.count > Self.maxCount {
      projects = Array(projects.prefix(Self.maxCount))
    }
    save()
  }

  func remove(repoRoot: String) {
    projects.removeAll { $0.repoRoot == repoRoot }
    save()
  }

  func clear() {
    projects.removeAll()
    save()
  }

  private func load() {
    guard let data = userDefaults.data(forKey: storageKey),
      let decoded = try? JSONDecoder().decode([RecentProject].self, from: data)
    else { return }
    projects = decoded
  }

  private func save() {
    if let data = try? JSONEncoder().encode(projects) {
      userDefaults.set(data, forKey: storageKey)
    }
  }
}
