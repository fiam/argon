import Foundation

@MainActor
@Observable
final class AgentAvailability {
  enum Status: Equatable {
    case checking
    case available
    case unavailable
  }

  struct Details: Equatable {
    let status: Status
    let resolvedPath: String?
    let version: String?

    static let checking = Details(status: .checking, resolvedPath: nil, version: nil)
    static let unavailable = Details(status: .unavailable, resolvedPath: nil, version: nil)
  }

  private(set) var revision = 0
  private var detailsByCommand: [String: Details] = [:]
  private var familiesByCommand: [String: AgentFamilyID?] = [:]
  private var pendingCommands: Set<String> = []
  private var probeTask: Task<Void, Never>?

  var hasPendingCommands: Bool {
    detailsByCommand.values.contains { $0.status == .checking }
  }

  func refresh(for profiles: [SavedAgentProfile]) {
    let commandsByFamily = Dictionary(
      profiles
        .map { profile in
          (
            profile.availabilityCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            profile.familyID
          )
        }
        .filter { !$0.0.isEmpty },
      uniquingKeysWith: { existing, replacement in existing ?? replacement }
    )

    var added = false
    for (command, familyID) in commandsByFamily where detailsByCommand[command] == nil {
      detailsByCommand[command] = .checking
      familiesByCommand[command] = familyID
      pendingCommands.insert(command)
      added = true
    }

    if added {
      revision += 1
    }
    startProbeLoopIfNeeded()
  }

  func status(for profile: SavedAgentProfile) -> Status {
    details(for: profile).status
  }

  func details(for profile: SavedAgentProfile) -> Details {
    let command = profile.availabilityCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return .unavailable }
    return detailsByCommand[command] ?? .checking
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

      let batchFamilies = Dictionary(
        uniqueKeysWithValues: batch.map { command in
          (command, familiesByCommand[command] ?? nil)
        })
      let results = await Task.detached(priority: .utility) {
        UserShell.commandDetails(batchFamilies)
      }.value

      for command in batch {
        guard let result = results[command], result.exists else {
          detailsByCommand[command] = .unavailable
          continue
        }
        let version = (familiesByCommand[command] ?? nil).flatMap { familyID in
          AgentHarnesses.displayVersion(for: familyID, rawOutput: result.version)
        }
        detailsByCommand[command] = Details(
          status: .available,
          resolvedPath: result.resolvedPath,
          version: version
        )
      }
      revision += 1
    }
  }
}
