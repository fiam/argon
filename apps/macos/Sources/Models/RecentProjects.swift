import Foundation

struct RecentProject: Codable, Identifiable, Hashable {
  var id: String { repoRoot }
  let repoRoot: String
  let repoName: String
  let lastOpened: Date
}

enum RecentProjectLastOpenedFormatter {
  static func label(
    for date: Date,
    relativeTo now: Date = .now,
    calendar: Calendar = .current
  ) -> String {
    let startOfDate = calendar.startOfDay(for: date)
    let startOfNow = calendar.startOfDay(for: now)
    let dayDelta = calendar.dateComponents([.day], from: startOfNow, to: startOfDate).day ?? 0

    switch dayDelta {
    case 0:
      return "Today"
    case -1:
      return "Yesterday"
    case 1:
      return "Tomorrow"
    default:
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .full
      return formatter.localizedString(from: DateComponents(day: dayDelta))
    }
  }
}

@MainActor
@Observable
final class RecentProjects {
  private static let defaultStorageKey = "recentProjects"
  private static let maxCount = 20

  private let userDefaults: UserDefaults
  private let storageKey: String
  private let fileManager: FileManager
  var projects: [RecentProject] = []

  init(
    userDefaults: UserDefaults = .standard,
    storageKey: String = defaultStorageKey,
    fileManager: FileManager = .default
  ) {
    self.userDefaults = userDefaults
    self.storageKey = storageKey
    self.fileManager = fileManager
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

  func pruneMissingProjects() {
    let filteredProjects = projects.filter { fileManager.fileExists(atPath: $0.repoRoot) }
    guard filteredProjects != projects else { return }
    projects = filteredProjects
    save()
  }

  private func load() {
    guard let data = userDefaults.data(forKey: storageKey),
      let decoded = try? JSONDecoder().decode([RecentProject].self, from: data)
    else { return }
    projects = decoded
    pruneMissingProjects()
  }

  private func save() {
    if let data = try? JSONEncoder().encode(projects) {
      userDefaults.set(data, forKey: storageKey)
    }
  }
}
