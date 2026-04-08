import Foundation

@MainActor
@Observable
final class AgentAvailability {
  enum Status: Equatable {
    case checking
    case available
    case unavailable
  }

  private(set) var revision = 0
  private var statuses: [String: Status] = [:]
  private var pendingCommands: Set<String> = []
  private var probeTask: Task<Void, Never>?

  var hasPendingCommands: Bool {
    statuses.values.contains(.checking)
  }

  func refresh(for profiles: [SavedAgentProfile]) {
    let commands = Set(
      profiles
        .map(\.baseCommand)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )

    var added = false
    for command in commands where statuses[command] == nil {
      statuses[command] = .checking
      pendingCommands.insert(command)
      added = true
    }

    if added {
      revision += 1
    }
    startProbeLoopIfNeeded()
  }

  func status(for profile: SavedAgentProfile) -> Status {
    let command = profile.baseCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return .unavailable }
    return statuses[command] ?? .checking
  }

  private func startProbeLoopIfNeeded() {
    guard probeTask == nil, !pendingCommands.isEmpty else { return }
    probeTask = Task { [weak self] in
      await self?.runProbeLoop()
    }
  }

  private func runProbeLoop() async {
    while true {
      let batch = Array(pendingCommands)
      pendingCommands.removeAll()
      guard !batch.isEmpty else {
        probeTask = nil
        return
      }

      let results = await Task.detached(priority: .utility) {
        UserShell.commandStatuses(batch)
      }.value

      for command in batch {
        statuses[command] = results[command] == true ? .available : .unavailable
      }
      revision += 1
    }
  }
}
