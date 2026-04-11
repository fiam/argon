import Foundation

struct SavedAgentProfile: Codable, Identifiable, Hashable {
  var id: String
  var name: String
  var command: String
  var icon: String
  /// Flags appended to the command to enable auto-approve mode.
  /// Empty string means the agent doesn't support a yolo mode.
  var yoloFlag: String

  /// Build the full command, optionally with yolo flags.
  func fullCommand(yolo: Bool, sandboxed: Bool = false) -> String {
    var components = [command]
    if yolo && !yoloFlag.isEmpty {
      components.append(yoloFlag)
    }
    return components.joined(separator: " ")
  }

  /// Convert to the AgentProfile used by the launch sheet.
  func toAgentProfile(isDetected: Bool) -> AgentProfile {
    AgentProfile(id: id, name: name, command: command, icon: icon, isDetected: isDetected)
  }

  var baseCommand: String {
    command.split(separator: " ").first.map(String.init) ?? command
  }
}

@MainActor
@Observable
final class SavedAgentProfiles {
  private static let key = "savedAgentProfiles"

  var profiles: [SavedAgentProfile] = []

  /// Well-known defaults shipped with the app.
  static let builtinDefaults: [SavedAgentProfile] = [
    SavedAgentProfile(
      id: "claude-code", name: "Claude Code",
      command: "claude", icon: "claude",
      yoloFlag: "--dangerously-skip-permissions"),
    SavedAgentProfile(
      id: "codex", name: "Codex",
      command: "codex", icon: "codex",
      yoloFlag: "--yolo"),
    SavedAgentProfile(
      id: "gemini", name: "Gemini CLI",
      command: "gemini", icon: "gemini",
      yoloFlag: "-y"),
  ]

  init() {
    load()
    if profiles.isEmpty {
      profiles = Self.builtinDefaults
      save()
    }
  }

  func add(_ profile: SavedAgentProfile) {
    profiles.append(profile)
    save()
  }

  func update(_ profile: SavedAgentProfile) {
    if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[idx] = profile
      save()
    }
  }

  func remove(at offsets: IndexSet) {
    profiles.remove(atOffsets: offsets)
    save()
  }

  func remove(id: String) {
    profiles.removeAll { $0.id == id }
    save()
  }

  func move(from source: IndexSet, to destination: Int) {
    profiles.move(fromOffsets: source, toOffset: destination)
    save()
  }

  func resetToDefaults() {
    profiles = Self.builtinDefaults
    save()
  }
  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Self.key),
      let decoded = try? JSONDecoder().decode([SavedAgentProfile].self, from: data)
    else { return }
    profiles = decoded
  }

  private func save() {
    if let data = try? JSONEncoder().encode(profiles) {
      UserDefaults.standard.set(data, forKey: Self.key)
    }
  }
}
