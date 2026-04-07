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
  private static let key = "recentProjects"
  private static let maxCount = 20

  var projects: [RecentProject] = []

  init() {
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
    guard let data = UserDefaults.standard.data(forKey: Self.key),
      let decoded = try? JSONDecoder().decode([RecentProject].self, from: data)
    else { return }
    projects = decoded
  }

  private func save() {
    if let data = try? JSONEncoder().encode(projects) {
      UserDefaults.standard.set(data, forKey: Self.key)
    }
  }
}
