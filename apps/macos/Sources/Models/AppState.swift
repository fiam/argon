import SwiftUI

@MainActor
@Observable
final class AppState {
    var session: ReviewSession?
    var files: [FileDiff] = []
    var selectedFile: FileDiff?
    var errorMessage: String?
    var isLoading = false
    var isPolling = false

    var sessionId: String?
    var repoRoot: String?

    private var pollTask: Task<Void, Never>?

    init() {
        parseArguments()
    }

    private func parseArguments() {
        let args = ProcessInfo.processInfo.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--session-id" where i + 1 < args.count:
                sessionId = args[i + 1]
                i += 2
            case "--repo-root" where i + 1 < args.count:
                repoRoot = args[i + 1]
                i += 2
            default:
                i += 1
            }
        }
    }

    func loadSession() {
        guard let sessionId, let repoRoot else {
            errorMessage = "No session. Run: argon . from a git repo"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let newSession = try SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
            session = newSession
            let rawDiff = GitService.diff(session: newSession)
            files = DiffParser.parse(rawDiff)
            if selectedFile == nil || !files.contains(where: { $0.id == selectedFile?.id }) {
                selectedFile = files.first
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reload() {
        errorMessage = nil
        loadSession()
    }

    /// Refresh only session metadata (threads, status, decision) without re-running git diff.
    func refreshSession() {
        guard let sessionId, let repoRoot else { return }
        do {
            session = try SessionLoader.loadSession(sessionId: sessionId, repoRoot: repoRoot)
        } catch {
            // Ignore transient read errors during polling
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { break }
                self?.refreshSession()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    func closeSession() {
        guard let sessionId, let repoRoot else { return }
        do {
            try ArgonCLI.closeSession(sessionId: sessionId, repoRoot: repoRoot)
            refreshSession()
        } catch {
            // Best effort on close
        }
        stopPolling()
    }

    func submitDecision(outcome: String, summary: String? = nil) {
        guard let sessionId, let repoRoot else { return }
        do {
            try ArgonCLI.setDecision(
                sessionId: sessionId, repoRoot: repoRoot,
                outcome: outcome, summary: summary
            )
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addComment(message: String, filePath: String? = nil, lineNew: UInt32? = nil, lineOld: UInt32? = nil, threadId: String? = nil) {
        guard let sessionId, let repoRoot else { return }
        do {
            try ArgonCLI.addComment(
                sessionId: sessionId, repoRoot: repoRoot,
                message: message, filePath: filePath,
                lineNew: lineNew, lineOld: lineOld, threadId: threadId
            )
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var handoffCommand: String {
        guard let sessionId, let repoRoot else { return "" }
        let cli = ProcessInfo.processInfo.environment["ARGON_CLI_CMD"] ?? "argon"
        return "\(cli) --repo \(repoRoot) agent prompt --session \(sessionId)"
    }
}
